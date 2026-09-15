import 'package:mssql_orm/orm.dart';

import 'config.dart';
import 'naming.dart';

/// One relation the generator will emit for a table.
class RelationPlan {
  const RelationPlan({
    required this.name,
    required this.kind,
    required this.target,
    required this.localColumns,
    required this.foreignColumns,
    this.through,
    this.morph,
  });

  /// The field name on the parent row.
  final String name;

  final MssqlRelationKind kind;

  /// `schema.Table` of the other side.
  final String target;

  final List<String> localColumns;
  final List<String> foreignColumns;

  /// Declared middle table. Never inferred from "two FKs".
  final RelationThroughPlan? through;

  /// Declared polymorphic mapping.
  final RelationMorphPlan? morph;

  bool get isToOne =>
      kind == MssqlRelationKind.belongsTo ||
      kind == MssqlRelationKind.hasOne ||
      kind == MssqlRelationKind.hasOneThrough ||
      kind == MssqlRelationKind.morphTo ||
      kind == MssqlRelationKind.morphOne;
}

class RelationThroughPlan {
  const RelationThroughPlan({
    required this.bindingTable,
    required this.nearColumns,
    required this.farColumns,
    this.typeColumn,
    this.typeValue,
  });

  final String bindingTable;
  final List<String> nearColumns;
  final List<String> farColumns;
  final String? typeColumn;
  final String? typeValue;
}

class RelationMorphPlan {
  const RelationMorphPlan({
    required this.typeColumn,
    required this.idColumn,
    this.typeValue,
    this.unknown = MssqlMorphUnknown.error,
    this.targets = const <String, String>{},
  });

  final String typeColumn;
  final String idColumn;
  final String? typeValue;
  final MssqlMorphUnknown unknown;
  final Map<String, String> targets;
}

/// Raised when two relations on one table would take the same name.
class RelationNameCollision implements Exception {
  const RelationNameCollision(this.table, this.name, this.targets);

  final String table;
  final String name;
  final List<String> targets;

  @override
  String toString() =>
      'RelationNameCollision: on $table, ${targets.join(' and ')} both want '
      'the relation name "$name". Name them explicitly under `relations:` in '
      'the configuration; a numbered suffix would leave nobody able to tell '
      'which is which.';
}

/// Derives every relation for [table] from foreign keys.
List<RelationPlan> relationsFor(
  MssqlTableSchema table,
  List<MssqlTableSchema> all, {
  KeyedSetting<String>? nameOverrides,
  Set<String> excluded = const <String>{},
  List<String>? warnings,
  List<DeclaredRelationConfig> declared = const <DeclaredRelationConfig>[],
}) {
  final plans = <RelationPlan>[];

  for (final fk in table.foreignKeys) {
    plans.add(
      RelationPlan(
        name: _belongsToName(fk),
        kind: MssqlRelationKind.belongsTo,
        target: fk.referencedQualifiedName,
        localColumns: fk.columns,
        foreignColumns: fk.referencedColumns,
      ),
    );
  }

  for (final other in all) {
    if (other.qualifiedName == table.qualifiedName &&
        other.foreignKeys.isEmpty) {
      continue;
    }
    for (final fk in other.foreignKeys) {
      if (fk.referencedQualifiedName.toLowerCase() !=
          table.qualifiedName.toLowerCase()) {
        continue;
      }
      // hasOne if the foreign key is unique, hasMany otherwise.
      // Filtered/disabled unique indexes do not count as unique.
      final single = other.isUnique(fk.columns);
      if (!single) {
        final conditional = other.uniqueKeyFor(
          fk.columns,
          requireUnconditional: false,
        );
        if (conditional != null) {
          warnings?.add(
            '${other.qualifiedName}.${fk.columns.join(', ')} is covered by '
            '${conditional.name}, but ${conditional.unusableReason}, so the '
            'relation from ${table.qualifiedName} is generated as hasMany. '
            'Declare it under `relations:` if one child per parent really is '
            'guaranteed.',
          );
        }
      }
      plans.add(
        RelationPlan(
          // The other side's table name, camel-cased: OrderLines -> orderLines.
          name: fieldName(other.name),
          kind: single ? MssqlRelationKind.hasOne : MssqlRelationKind.hasMany,
          target: other.qualifiedName,
          localColumns: fk.referencedColumns,
          foreignColumns: fk.columns,
        ),
      );
    }
  }

  final renamed = <RelationPlan>[
    for (final plan in plans)
      if (!excluded.any(
        (k) => KeyedSetting.matches(k, '${table.qualifiedName}.${plan.name}'),
      ))
        RelationPlan(
          name:
              nameOverrides?['${table.qualifiedName}.${plan.name}'] ??
              plan.name,
          kind: plan.kind,
          target: plan.target,
          localColumns: plan.localColumns,
          foreignColumns: plan.foreignColumns,
          through: plan.through,
          morph: plan.morph,
        ),
  ];

  for (final declared in declared) {
    if (!KeyedSetting.matches(declared.owner, table.qualifiedName)) continue;
    renamed.add(_fromDeclared(declared));
  }

  final derived = <String>{for (final plan in plans) plan.name};
  for (final key in nameOverrides?.keys ?? const <String>[]) {
    final name = _relationPart(key, table);
    if (name != null && !derived.contains(name)) {
      throw UnknownRelationOverride('relation_names', key, derived);
    }
  }
  for (final key in excluded) {
    final name = _relationPart(key, table);
    if (name != null && !derived.contains(name)) {
      throw UnknownRelationOverride('exclude_relations', key, derived);
    }
  }

  final byName = <String, List<String>>{};
  for (final plan in renamed) {
    byName.putIfAbsent(plan.name, () => <String>[]).add(plan.target);
  }
  for (final entry in byName.entries) {
    if (entry.value.length > 1) {
      throw RelationNameCollision(table.qualifiedName, entry.key, entry.value);
    }
  }

  renamed.sort((a, b) => a.name.compareTo(b.name));
  return renamed;
}

RelationPlan _fromDeclared(DeclaredRelationConfig declared) {
  final kind = _parseKind(declared.kind, declared.owner, declared.name);
  final needsThrough = const <MssqlRelationKind>{
    MssqlRelationKind.belongsToMany,
    MssqlRelationKind.hasOneThrough,
    MssqlRelationKind.hasManyThrough,
    MssqlRelationKind.morphToMany,
  }.contains(kind);
  final needsMorph = const <MssqlRelationKind>{
    MssqlRelationKind.morphTo,
    MssqlRelationKind.morphOne,
    MssqlRelationKind.morphMany,
  }.contains(kind);
  if (needsThrough && (declared.through == null || declared.through!.isEmpty)) {
    throw ConfigError(
      'declared_relations.${declared.owner}.${declared.name} is ${kind.name} '
      'and needs through:, near: and far:. A pivot is never inferred from '
      'two foreign keys.',
    );
  }
  if (needsMorph &&
      (declared.typeColumn == null ||
          (kind == MssqlRelationKind.morphTo
              ? declared.idColumn == null
              : declared.typeValue == null))) {
    throw ConfigError(
      'declared_relations.${declared.owner}.${declared.name} is ${kind.name} '
      'and needs type_column: plus id_column: (morphTo) or type_value: '
      '(morphOne/morphMany).',
    );
  }
  if (kind == MssqlRelationKind.morphTo && declared.targets.isEmpty) {
    throw ConfigError(
      'declared_relations.${declared.owner}.${declared.name} is morphTo and '
      'needs targets: mapping discriminator values to tables.',
    );
  }
  final unknown = switch (declared.unknown) {
    'error' => MssqlMorphUnknown.error,
    'ignore' => MssqlMorphUnknown.ignore,
    _ => throw ConfigError(
      'declared_relations.${declared.owner}.${declared.name} unknown: '
      'must be error or ignore, not "${declared.unknown}".',
    ),
  };
  return RelationPlan(
    name: declared.name,
    kind: kind,
    target: declared.target,
    localColumns: declared.localColumns,
    foreignColumns: declared.foreignColumns,
    through: declared.through == null
        ? null
        : RelationThroughPlan(
            bindingTable: declared.through!,
            nearColumns: declared.nearColumns,
            farColumns: declared.farColumns,
            typeColumn: declared.typeColumn,
            typeValue: declared.typeValue,
          ),
    morph: needsMorph || kind == MssqlRelationKind.morphToMany
        ? RelationMorphPlan(
            typeColumn: declared.typeColumn ?? '',
            idColumn: declared.idColumn ?? '',
            typeValue: declared.typeValue,
            unknown: unknown,
            targets: declared.targets,
          )
        : null,
  );
}

MssqlRelationKind _parseKind(String kind, String owner, String name) {
  for (final value in MssqlRelationKind.values) {
    if (value.name.toLowerCase() == kind.toLowerCase()) return value;
  }
  throw ConfigError(
    'declared_relations.$owner.$name kind "$kind" is not a known '
    'MssqlRelationKind.',
  );
}

/// Raised when a relation override names a relation that does not exist.
///
/// The column and class overrides already refuse a name nothing matches;
/// leaving relations out of that made a typo silently do nothing.
class UnknownRelationOverride implements Exception {
  const UnknownRelationOverride(this.setting, this.key, this.known);

  final String setting;
  final String key;
  final Set<String> known;

  @override
  String toString() =>
      'UnknownRelationOverride: $setting names "$key", which is not a relation '
      'the foreign keys produce. '
      '${known.isEmpty ? 'This table has no relations.' : 'It has: '
                '${(known.toList()..sort()).join(', ')}.'}';
}

/// `CustomerId` becomes `customer`; a composite or oddly named key keeps the
/// referenced table's name instead.
String _belongsToName(MssqlForeignKeySchema fk) {
  if (fk.columns.length == 1) {
    final column = fk.columns.single;
    final lower = column.toLowerCase();
    if (lower.endsWith('id') && column.length > 2) {
      return fieldName(column.substring(0, column.length - 2));
    }
  }
  return fieldName(fk.referencedTable);
}

/// The relation half of a `schema.Table.relation` key, when the key names
/// [table], and null when it names a different one.
String? _relationPart(String key, MssqlTableSchema table) {
  final dot = key.lastIndexOf('.');
  if (dot <= 0) return null;
  final owner = key.substring(0, dot);
  if (!KeyedSetting.matches(owner, table.qualifiedName)) return null;
  return key.substring(dot + 1);
}
