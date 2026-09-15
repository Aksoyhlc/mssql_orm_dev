import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';

import 'config.dart';
import 'dart_type.dart';
import 'generation_banner.dart';
import 'naming.dart';
import 'relations.dart';

part 'emit/fields_emitter.dart';
part 'emit/projection_emitter.dart';
part 'emit/query_emitter.dart';

/// One table's worth of decisions, made once and read by both emitters.
class TablePlan {
  TablePlan._({
    required this.table,
    required this.rowClass,
    required this.columnsClass,
    required this.repositoryClass,
    required this.queryClass,
    required this.fieldsClass,
    required this.fileName,
    required this.fields,
    required this.strategy,
    required this.keyType,
    required this.fingerprint,
    required this.config,
    required this.relations,
  });

  /// [world] is every table the run selected, needed because a hasMany is a
  /// foreign key on *another* table pointing here.
  factory TablePlan.of(
    MssqlTableSchema table,
    GeneratorConfig config, {
    List<MssqlTableSchema> world = const <MssqlTableSchema>[],
    List<String>? relationWarnings,
  }) {
    final qualified = table.qualifiedName;
    final baseName = config.classNames[qualified] ?? className(table.name);

    final fields = <FieldPlan>[];
    final byDart = <String, String>{};
    for (final column in table.columns) {
      final key = '$qualified.${column.name}';
      final dartName = config.fieldNames[key] ?? fieldName(column.name);
      byDart[column.name] = dartName;
      final type = _mappedDartType(config, table, column, qualified);
      fields.add(
        FieldPlan(
          column: column,
          dartName: dartName,
          type: type,
          readOnly: type.forcedReadOnly || _matches(config.readOnlyColumns, qualified, column.name),
          hidden: _matches(config.hiddenColumns, qualified, column.name),
        ),
      );
    }
    checkDistinct(qualified, byDart);

    final strategy = table.isView
        ? MssqlInsertStrategy.noKeyReadback
        : table.identityColumn == null
        ? MssqlInsertStrategy.noKeyReadback
        // SQL Server rejects an OUTPUT clause without INTO on a table carrying
        // any enabled trigger — error 334, and not only for INSTEAD OF ones.
        : table.hasEnabledTrigger
        ? MssqlInsertStrategy.scopeIdentity
        : MssqlInsertStrategy.outputInserted;

    final key = table.primaryKey;
    String keyType;
    if (key == null || table.isView) {
      keyType = 'Never';
    } else if (key.columns.length == 1) {
      final field = fields.firstWhere((f) => f.column.name.toLowerCase() == key.columns.single.toLowerCase());
      keyType = field.type.declared(field.column.nullable);
    } else {
      keyType = '${baseName}Key';
    }

    final plan = TablePlan._(
      table: table,
      rowClass: '${baseName}Row',
      columnsClass: baseName,
      repositoryClass: '${baseName}Repository',
      queryClass: '${baseName}Query',
      fieldsClass: '${baseName}Fields',
      fileName: sourceFileName(table.name),
      fields: fields,
      strategy: strategy,
      keyType: keyType,
      fingerprint: fingerprintOf(table),
      config: config,
      relations: world.isEmpty
          ? const <RelationPlan>[]
          : relationsFor(
              table,
              world,
              nameOverrides: config.relationNames,
              excluded: config.excludedRelations.toSet(),
              warnings: relationWarnings,
              declared: config.declaredRelations,
            ),
    );
    _validateQueryApi(plan);
    _validateRelationFields(plan);
    if (relationWarnings != null) {
      if (!config.softDeleteColumns.contains(qualified) && plan.softDeleteColumn != null) {
        relationWarnings.add(
          '${table.qualifiedName}: convention soft-delete column '
          '"${plan.softDeleteColumn}". Set soft_delete_columns.'
          '${table.name}: false to opt out.',
        );
      }
      if (!config.timestampColumns.contains(qualified) && plan.timestampColumns != null) {
        relationWarnings.add(
          '${table.qualifiedName}: convention timestamp columns '
          '${plan.timestampColumns!.createdColumn ?? "-"}/'
          '${plan.timestampColumns!.updatedColumn ?? "-"}.',
        );
      }
    }
    return plan;
  }

  final MssqlTableSchema table;
  final String rowClass;
  final String columnsClass;
  final String repositoryClass;

  /// Generated query type: `OrdersQuery`.
  final String queryClass;

  /// Callback fields type: `OrdersFields`.
  final String fieldsClass;
  final String fileName;
  final List<FieldPlan> fields;
  final MssqlInsertStrategy strategy;
  final String keyType;
  final String fingerprint;
  final GeneratorConfig config;
  final List<RelationPlan> relations;

  bool get hasRelations => relations.isNotEmpty;

  bool get scaffold => config.scaffold;

  /// With scaffolding on, the generated class is the base and the one you own
  /// carries the plain name.
  String get rowBase => scaffold ? '${rowClass}Base' : rowClass;
  String get repositoryBase => scaffold ? '${repositoryClass}Base' : repositoryClass;

  /// The generated equality shortcut for [field], e.g. `whereStatus`.
  String whereShortcut(FieldPlan field) {
    final path = '${table.qualifiedName}.${field.column.name}';
    final override = config.queryMethods[path];
    if (override != null && override.isNotEmpty) return override;
    return whereShortcutName(field.dartName);
  }

  bool get hasKey => table.primaryKey != null && !table.isView;

  /// Parent-key field used by generated hierarchy traversal.
  FieldPlan? get hierarchyParentField {
    if (!hasKey || compositeKey) return null;
    final qualified = table.qualifiedName;
    final keyColumn = table.primaryKey!.columns.single.toLowerCase();
    String? declared;
    if (config.hierarchyParents.contains(qualified)) {
      declared = _canonicalColumn(config.hierarchyParents[qualified]);
      if (declared == null) return null;
    } else {
      final selfKeys = <MssqlForeignKeySchema>[
        for (final fk in table.foreignKeys)
          if (fk.referencedQualifiedName.toLowerCase() == qualified.toLowerCase() &&
              fk.columns.length == 1 &&
              fk.referencedColumns.length == 1 &&
              fk.referencedColumns.single.toLowerCase() == keyColumn)
            fk,
      ];
      if (selfKeys.length != 1) return null;
      declared = _canonicalColumn(selfKeys.single.columns.single);
    }
    if (declared == null) return null;
    final lower = declared.toLowerCase();
    // Hierarchy traversal compares parent and key values with the same type.
    FieldPlan? parent;
    for (final field in fields) {
      if (field.column.name.toLowerCase() == lower) parent = field;
    }
    if (parent == null) return null;
    final key = keyField;
    if (key == null || parent.type.name != key.type.name) return null;
    return parent;
  }

  /// The single primary-key field, or null for a composite or keyless table.
  FieldPlan? get keyField {
    if (!hasKey || compositeKey) return null;
    final name = table.primaryKey!.columns.single.toLowerCase();
    for (final field in fields) {
      if (field.column.name.toLowerCase() == name) return field;
    }
    return null;
  }

  bool get compositeKey => (table.primaryKey?.columns.length ?? 0) > 1;

  /// A view, or a table with no primary key, cannot address one row.
  bool get readOnly => !hasKey;

  /// Soft-delete column using explicit configuration before convention.
  ///
  /// Returns the schema's original spelling for case-sensitive collations.
  String? get softDeleteColumn {
    final byTable = config.softDeleteColumns;
    if (byTable.contains(table.qualifiedName)) {
      return _canonicalColumn(byTable[table.qualifiedName]);
    }
    return _conventionColumn(config.conventions.softDelete, softDelete: true);
  }

  /// The timestamp columns, from the table's own entry or the convention.
  TimestampColumnsConfig? get timestampColumns {
    final declared = config.timestampColumns[table.qualifiedName];
    if (declared != null) {
      return TimestampColumnsConfig(
        createdColumn: _canonicalColumn(declared.createdColumn),
        updatedColumn: _canonicalColumn(declared.updatedColumn),
      );
    }
    final created = _conventionColumn(config.conventions.createdAt);
    final updated = _conventionColumn(config.conventions.updatedAt);
    if (created == null && updated == null) return null;
    return TimestampColumnsConfig(createdColumn: created, updatedColumn: updated);
  }

  /// The column [convention] means on this table, or null.
  String? _conventionColumn(String? convention, {bool softDelete = false}) {
    if (convention == null) return null;
    for (final field in fields) {
      if (!ConventionsConfig.matches(field.column.name, convention)) continue;
      if (!field.writable) return null;
      if (!_isDateTime(field.column.type)) return null;
      if (softDelete && !field.column.nullable) return null;
      return field.column.name;
    }
    return null;
  }

  static bool _isDateTime(MssqlType type) => const <MssqlType>{
    MssqlType.date,
    MssqlType.smallDateTime,
    MssqlType.dateTime,
    MssqlType.dateTime2,
    MssqlType.dateTimeOffset,
  }.contains(type);

  /// Returns [name] as the schema spells it, or unchanged when the table has
  /// no such column — the generator's own validation is what reports that.
  String? _canonicalColumn(String? name) {
    if (name == null) return null;
    final lower = name.toLowerCase();
    for (final field in fields) {
      if (field.column.name.toLowerCase() == lower) return field.column.name;
    }
    return name;
  }

  List<FieldPlan> get keyFields => <FieldPlan>[
    for (final name in table.primaryKey?.columns ?? const <String>[])
      fields.firstWhere((f) => f.column.name.toLowerCase() == name.toLowerCase()),
  ];

  /// This plan as a binding, without generating any Dart.
  MssqlTableBinding<Object?> asBinding() => MssqlTableBinding<Object?>(
    schema: table.schema,
    table: table.name,
    primaryKey: table.primaryKey?.columns ?? const <String>[],
    identityColumn: table.identityColumn?.name,
    insertStrategy: strategy,
    decimalMode: config.decimalMode,
    apiVersion: MssqlApiVersion.current,
    schemaFingerprint: fingerprint,
    softDelete: softDeleteColumn == null ? null : MssqlSoftDelete(column: softDeleteColumn!),
    timestamps: MssqlTimestamps(
      createdColumn: timestampColumns?.createdColumn,
      updatedColumn: timestampColumns?.updatedColumn,
    ),
    columns: <MssqlBoundColumn>[
      for (final field in fields)
        MssqlBoundColumn(
          name: field.column.name,
          type: field.column.type,
          nullable: field.column.nullable,
          isIdentity: field.column.isIdentity,
          isComputed: field.column.isComputed,
          isRowVersion: field.column.isRowVersion,
          hasDefault: field.column.hasDefault,
          isReadOnly: field.readOnly,
          maxLength: field.column.maxLength,
          precision: field.column.precision,
          scale: field.column.scale,
        ),
    ],
    fromRow: (row) => row,
    toColumns: (row) => const <String, Object?>{},
    readColumn: (row, name) => (row as MssqlRow)[name],
  );

  FieldPlan? get identityField {
    final name = table.identityColumn?.name;
    if (name == null) return null;
    return fields.firstWhere((f) => f.column.name == name);
  }
}

class FieldPlan {
  const FieldPlan({
    required this.column,
    required this.dartName,
    required this.type,
    required this.readOnly,
    required this.hidden,
  });

  final MssqlColumnSchema column;
  final String dartName;
  final DartFieldType type;

  /// The schema allows writing it; the configuration says not to.
  final bool readOnly;

  /// Left out of `toJson`.
  final bool hidden;

  bool get nullable => column.nullable;
  String get declaredType => type.declared(nullable);
  bool get writable => !column.isServerGenerated && !readOnly;
}

bool _omitFromToString(FieldPlan field) {
  if (field.hidden) return true;
  final dart = field.dartName.toLowerCase();
  final sql = field.column.name.toLowerCase();
  return dart.contains('password') ||
      dart.contains('secret') ||
      dart == 'pwd' ||
      sql.contains('password') ||
      sql.contains('secret');
}

String _toStringBody(Iterable<FieldPlan> fields) => fields
    .where((field) => !_omitFromToString(field))
    .map((field) => '${field.dartName}: \$${field.dartName}')
    .join(', ');

/// Whether any of [patterns] names this column.
bool _matches(List<String> patterns, String qualifiedTable, String column) {
  final folded = column.toLowerCase();
  for (final pattern in patterns) {
    if (pattern.startsWith('*.')) {
      if (pattern.substring(2).toLowerCase() == folded) return true;
      continue;
    }
    if (KeyedSetting.matches(pattern, '$qualifiedTable.$column')) return true;
  }
  return false;
}

V? _configForColumn<V>(Map<String, V> map, String qualified, String column) {
  final path = '$qualified.$column';
  for (final entry in map.entries) {
    if (KeyedSetting.matches(entry.key, path)) return entry.value;
  }
  return null;
}

DartFieldType _mappedDartType(
  GeneratorConfig config,
  MssqlTableSchema table,
  MssqlColumnSchema column,
  String qualified,
) {
  final enumCfg = _configForColumn(config.enumColumns, qualified, column.name);
  if (enumCfg != null) {
    return DartFieldType(
      name: enumCfg.dartType,
      readable: (access, nullable) {
        final call = '_read${enumCfg.dartType}($access)';
        return nullable ? '$access == null ? null : $call' : call;
      },
      note:
          'Mapped by enum_columns; unknown SQL values use '
          '${enumCfg.unknown.name}.',
    );
  }
  final converter = _configForColumn(config.converters, qualified, column.name);
  if (converter != null) {
    return DartFieldType(
      name: converter.dartType,
      readable: (access, nullable) {
        final call = 'const ${converter.converter}().fromSql($access)';
        return nullable ? '$access == null ? null : $call' : call;
      },
      note: 'Mapped by converters: ${converter.converter}.',
    );
  }
  return dartTypeFor(table, column, decimalMode: config.decimalMode);
}

Set<String> _mappingImports(TablePlan plan, FieldPlan field) {
  final enumCfg = _configForColumn(plan.config.enumColumns, plan.table.qualifiedName, field.column.name);
  final converter = _configForColumn(plan.config.converters, plan.table.qualifiedName, field.column.name);
  return <String>{
    if (enumCfg?.importUri != null) enumCfg!.importUri!,
    if (converter?.importUri != null) converter!.importUri!,
  };
}

void _emitMappingHelpers(StringBuffer out, TablePlan plan) {
  final emitted = <String>{};
  for (final field in plan.fields) {
    final cfg = _configForColumn(plan.config.enumColumns, plan.table.qualifiedName, field.column.name);
    if (cfg == null || !emitted.add(cfg.dartType)) continue;
    out.writeln();
    out.writeln('${cfg.dartType} _read${cfg.dartType}(Object? value) {');
    out.writeln('  final text = value as String;');
    out.writeln('  for (final item in ${cfg.dartType}.values) {');
    out.writeln('    if (item.name == text) return item;');
    out.writeln('  }');
    if (cfg.unknown == EnumUnknownPolicy.error) {
      out.writeln('  throw MssqlUnknownEnumValueException(');
      out.writeln("    type: '${cfg.dartType}',");
      out.writeln('    value: text,');
      out.writeln("    source: '${plan.table.qualifiedName}.${field.column.name}',");
      out.writeln('  );');
    } else {
      out.writeln('  return ${cfg.dartType}.${cfg.unknownMember};');
    }
    out.writeln('}');
  }
}

/// Writes the file the generator owns and rewrites on every run.
String emitGenerated(TablePlan plan, {required String version}) {
  final out = StringBuffer();
  final table = plan.table;

  writeGenerationBanner(out, version: version, source: table.qualifiedName);
  out.writeln('// Schema fingerprint: ${plan.fingerprint}');
  if (table.foreignKeys.isNotEmpty) {
    out.writeln('//');
    out.writeln('// Foreign keys:');
    for (final fk in table.foreignKeys) {
      out.writeln(
        '//   ${fk.columns.join(', ')} -> '
        '${fk.referencedQualifiedName} (${fk.referencedColumns.join(', ')})',
      );
    }
  }
  if (plan.scaffold) {
    out.writeln('//');
    out.writeln('// Application code belongs in ../models/${plan.fileName}.dart,');
    out.writeln('// which this generator creates once and never touches again.');
  }
  out.writeln();

  final needsTypedData = plan.fields.any((f) => f.type.name == 'Uint8List');
  if (plan.config.json && needsTypedData) {
    out.writeln("import 'dart:convert';");
  }
  if (needsTypedData) out.writeln("import 'dart:typed_data';");
  out.writeln("import 'package:meta/meta.dart';");
  out.writeln("import 'package:mssql_native/mssql_native.dart';");
  out.writeln("import 'package:mssql_orm/orm.dart';");
  // A relation names another table's generated types. The imports run both
  // ways between two related tables, which Dart allows.
  final relatedFiles = <String>{for (final relation in plan.relations) sourceFileName(relation.target.split('.').last)}
    ..remove(plan.fileName);
  if (plan.scaffold) {
    final modelImports = <String>{plan.fileName, ...relatedFiles};
    for (final file in modelImports.toList()..sort()) {
      out.writeln("import '../models/$file.dart';");
    }
  } else {
    for (final file in relatedFiles.toList()..sort()) {
      out.writeln("import '$file.g.dart';");
    }
  }
  final extraImports = <String>{for (final field in plan.fields) ..._mappingImports(plan, field)};
  for (final uri in extraImports.toList()..sort()) {
    out.writeln("import '$uri';");
  }
  out.writeln();

  _emitRowClass(out, plan);
  out.writeln();
  _emitCreateClass(out, plan);
  out.writeln();
  _emitPatchClass(out, plan);
  out.writeln();
  _emitUniqueClass(out, plan);
  out.writeln();
  _emitColumnsClass(out, plan);
  out.writeln();
  if (plan.hasRelations) {
    _emitRelationsClass(out, plan);
    out.writeln();
  }
  _emitFieldsClass(out, plan);
  if (plan.compositeKey) {
    _emitKeyClass(out, plan);
    out.writeln();
  }
  _emitQueryClass(out, plan);
  out.writeln();
  _emitRepositoryClass(out, plan);
  _emitProjections(out, plan);
  _emitMappingHelpers(out, plan);

  return out.toString();
}

void _emitRowClass(StringBuffer out, TablePlan plan) {
  final concrete = plan.rowClass;
  final name = plan.rowBase;

  out.writeln('/// One row of ${plan.table.qualifiedName}.');
  if (plan.scaffold) {
    out.writeln('///');
    out.writeln('/// `copyWith` and `==` cover the fields declared here. A');
    out.writeln('/// field added to $concrete is not carried by either, which');
    out.writeln('/// is inherent to the split; adding behaviour is free.');
  }
  out.writeln('@immutable');
  out.writeln('class $name {');

  out.write('  const $name({');
  for (final field in plan.fields) {
    out.write(field.nullable ? 'this.${field.dartName}, ' : 'required this.${field.dartName}, ');
  }
  for (final relation in plan.relations) {
    out.write('${_relationType(plan, relation)}? ${relation.name}, ');
  }
  if (plan.hasRelations) {
    out.write('Set<String> loadedRelations = const <String>{}, ');
    out.write('Map<String, int> truncatedRelations = const <String, int>{}, ');
  }
  if (plan.hasRelations) {
    out.write('}) : ');
    out.write(
      plan.relations
          .map((r) => '_${r.name} = ${r.name}')
          .followedBy(<String>['_loadedRelations = loadedRelations', '_truncatedRelations = truncatedRelations'])
          .join(', '),
    );
    out.writeln(';');
  } else {
    out.writeln('});');
  }
  out.writeln();

  for (final field in plan.fields) {
    final notes = <String>[
      if (field.column.isIdentity) 'IDENTITY.',
      if (field.column.isComputed) 'Computed by the server.',
      if (field.readOnly && !field.type.forcedReadOnly) 'Marked read-only: never written by insert or update.',
      if (field.type.note != null) field.type.note!,
    ];
    for (final note in notes) {
      out.writeln('  /// $note');
    }
    out.writeln('  final ${field.declaredType} ${field.dartName};');
  }
  if (plan.hasRelations) {
    out.writeln();
    for (final relation in plan.relations) {
      out.writeln('  final ${_relationType(plan, relation)}? _${relation.name};');
    }
    out.writeln('  final Set<String> _loadedRelations;');
    out.writeln('  final Map<String, int> _truncatedRelations;');
    out.writeln();
    out.writeln('  /// Whether [relation] was loaded for this row.');
    out.writeln('  ///');
    out.writeln('  /// True for loaded-null and loaded-empty. Truncated is');
    out.writeln('  /// still loaded; [isTruncated] is the incomplete flag.');
    out.writeln('  bool isLoaded(String relation) =>');
    out.writeln('      _loadedRelations.contains(relation);');
    out.writeln();
    out.writeln('  /// Typed form of [isLoaded]: the handle, not a string.');
    out.writeln('  bool relationLoaded<TChild>(MssqlRelation<$concrete, TChild> relation) =>');
    out.writeln('      isLoaded(relation.name);');
    out.writeln();
    out.writeln('  /// Whether [relation] hit maxLoadedRows.');
    out.writeln('  bool isTruncated(String relation) =>');
    out.writeln('      _truncatedRelations.containsKey(relation);');
    for (final relation in plan.relations) {
      out.writeln();
      if (relation.isToOne) {
        out.writeln('  /// Throws when the relation was not loaded.');
        out.writeln('  /// Null means it was loaded and no related row exists.');
        out.writeln('  ${_relationType(plan, relation)}? get ${relation.name} {');
      } else {
        out.writeln('  /// Throws when the relation was not loaded. An empty');
        out.writeln('  /// list means loaded and none.');
        out.writeln('  ${_relationType(plan, relation)} get ${relation.name} {');
      }
      out.writeln("    if (!_loadedRelations.contains('${relation.name}')) {");
      out.writeln('      throw MssqlRelationNotLoadedException(');
      out.writeln(
        "        ${dartStringLiteral(plan.table.qualifiedName)}, "
        "${dartStringLiteral(relation.name)},",
      );
      out.writeln('      );');
      out.writeln('    }');
      out.writeln("    if (_truncatedRelations.containsKey('${relation.name}')) {");
      out.writeln('      throw MssqlRelationTruncatedException(');
      out.writeln("        table: ${dartStringLiteral(plan.table.qualifiedName)},");
      out.writeln("        relation: ${dartStringLiteral(relation.name)},");
      out.writeln("        limit: _truncatedRelations['${relation.name}']!,");
      out.writeln('      );');
      out.writeln('    }');
      out.writeln(relation.isToOne ? '    return _${relation.name};' : '    return _${relation.name} ?? const [];');
      out.writeln('  }');
    }
  }
  out.writeln();

  // fromRow
  out.writeln('  /// Reads a row by ordinal after checking column names.');
  out.writeln('  ///');
  out.writeln('  /// Name lookup on every field would rebuild a map the');
  out.writeln('  /// driver already has. Extra trailing columns are allowed');
  out.writeln('  /// so a withCount projection can append aggregates.');
  out.writeln(
    '  static const List<String> columnOrder = <String>[${plan.fields.map((f) => dartStringLiteral(f.column.name)).join(', ')}];',
  );
  out.writeln('  static $concrete fromRow(MssqlRow row) {');
  out.writeln('    row.assertOrdinalNames(columnOrder);');
  out.writeln('    return $concrete(');
  for (var i = 0; i < plan.fields.length; i++) {
    final field = plan.fields[i];
    final access = 'row.at($i)';
    out.writeln('      ${field.dartName}: ${field.type.readable(access, field.nullable)},');
  }
  out.writeln('    );');
  out.writeln('  }');
  out.writeln();
  out.writeln('  /// One column of this row, by SQL name.');
  out.writeln('  Object? columnValue(String name) => switch (name) {');
  for (final field in plan.fields) {
    out.writeln('    ${dartStringLiteral(field.column.name)} => ${field.dartName},');
  }
  out.writeln(
    "    _ => throw ArgumentError.value(name, 'name', "
    "'$concrete has no column named \"\$name\".'),",
  );
  out.writeln('  };');
  out.writeln();

  out.writeln('  Map<String, Object?> toColumns() => <String, Object?>{');
  for (final field in plan.fields) {
    out.writeln(
      '    ${dartStringLiteral(field.column.name)}: '
      '${_toSqlExpression(field)},',
    );
  }
  out.writeln('  };');
  out.writeln();

  // copyWith
  out.write('  $concrete copyWith({');
  for (final field in plan.fields) {
    out.write('${field.type.name}? ${field.dartName}, ');
  }
  out.writeln('}) => $concrete(');
  for (final field in plan.fields) {
    out.writeln('    ${field.dartName}: ${field.dartName} ?? this.${field.dartName},');
  }
  for (final relation in plan.relations) {
    out.writeln('    ${relation.name}: _${relation.name},');
  }
  if (plan.hasRelations) {
    out.writeln('    loadedRelations: _loadedRelations,');
    out.writeln('    truncatedRelations: _truncatedRelations,');
  }
  out.writeln('  );');
  out.writeln();

  if (plan.hasRelations) {
    out.writeln('  /// Returns a copy carrying the loaded relations.');
    out.writeln('  ///');
    out.writeln('  /// Rows are immutable, so the loader cannot write into');
    out.writeln('  /// one; it asks for a new row instead.');
    out.writeln('  $concrete withRelations(Map<String, Object?> relations) => $concrete(');
    for (final field in plan.fields) {
      out.writeln('    ${field.dartName}: ${field.dartName},');
    }
    for (final relation in plan.relations) {
      final type = _relationType(plan, relation);
      out.writeln("    ${relation.name}: relations.containsKey('${relation.name}')");
      out.writeln(
        relation.isToOne
            ? '        ? relations[\'${relation.name}\'] as $type?'
            : '        ? (relations[\'${relation.name}\']! as List<Object?>)'
                  '.cast<${type.substring(5, type.length - 1)}>()',
      );
      out.writeln('        : _${relation.name},');
    }
    out.writeln('    loadedRelations: <String>{');
    out.writeln('      ..._loadedRelations,');
    out.writeln('      for (final key in relations.keys)');
    out.writeln("        if (key != mssqlTruncatedRelationsKey) key,");
    out.writeln('    },');
    out.writeln('    truncatedRelations: <String, int>{');
    out.writeln('      ..._truncatedRelations,');
    out.writeln(
      "      if (relations[mssqlTruncatedRelationsKey] "
      "case final Map<Object?, Object?> extra)",
    );
    out.writeln('        for (final entry in extra.entries)');
    out.writeln('          entry.key.toString(): (entry.value as num).toInt(),');
    out.writeln('    },');
    out.writeln('  );');
    out.writeln();
  }

  if (plan.config.json) {
    _emitJson(out, plan, concrete);
  }

  // Equality over the declared fields.
  out.writeln('  @override');
  out.writeln('  bool operator ==(Object other) =>');
  out.writeln('      identical(this, other) ||');
  out.write('      other is $name');
  for (final field in plan.fields) {
    out.write(' && other.${field.dartName} == ${field.dartName}');
  }
  out.writeln(';');
  out.writeln();
  out.writeln('  @override');
  out.write('  int get hashCode => Object.hashAll(<Object?>[');
  out.write(plan.fields.map((f) => f.dartName).join(', '));
  out.writeln(']);');
  out.writeln();
  out.writeln('  @override');
  out.write("  String toString() => '$concrete(");
  out.write(_toStringBody(plan.fields));
  out.writeln(")';");
  out.writeln('}');
}

/// A column the caller must supply: it can be neither omitted nor nulled.
bool _createIsRequired(FieldPlan field) => !field.nullable && !field.column.hasDefault;

/// A column where omitting and nulling are different writes.
bool _createIsTriState(FieldPlan field) => field.nullable && field.column.hasDefault;

String _createFieldType(FieldPlan field) {
  if (_createIsRequired(field)) return field.declaredType;
  if (_createIsTriState(field)) return 'Field<${field.type.name}?>';
  return '${field.type.name}?';
}

/// Emits the Create model: what a caller assembles to insert one row.
void _emitCreateClass(StringBuffer out, TablePlan plan) {
  final name = '${plan.rowBase}Create';
  final createFields = plan.fields.where((f) => f.writable).toList();

  out.writeln(
    '/// Values for inserting one row into '
    '${plan.table.qualifiedName}.',
  );
  out.writeln('///');
  out.writeln('/// Identity, computed, rowversion and read-only columns');
  out.writeln('/// are absent: the server owns them. A non-null column');
  out.writeln('/// without a default is required; a defaulted column is');
  out.writeln('/// optional, and omitting it means SQL DEFAULT. A column');
  out.writeln('/// that is both nullable and defaulted is a [Field], so');
  out.writeln('/// that `Field.absent()` (use the DEFAULT) and');
  out.writeln('/// `Field.value(null)` (write NULL) stay distinguishable.');
  out.writeln('@immutable');
  out.writeln('class $name {');
  if (createFields.isEmpty) {
    // `const X({});` is not Dart: an empty named-parameter list needs no
    // braces at all. A table whose every column is an identity, a computed
    // column, a rowversion or read-only reaches this — nothing is left for
    // the caller to supply — and it is a legitimate table, so the Create
    // class exists and takes nothing. The insert becomes `DEFAULT VALUES`.
    out.writeln('  const $name();');
  } else {
    out.write('  const $name({');
    for (final field in createFields) {
      if (_createIsRequired(field)) {
        out.write('required this.${field.dartName}, ');
      } else if (_createIsTriState(field)) {
        out.write('this.${field.dartName} = const Field.absent(), ');
      } else {
        out.write('this.${field.dartName}, ');
      }
    }
    out.writeln('});');
  }
  out.writeln();

  for (final field in createFields) {
    final notes = <String>[
      if (field.column.hasDefault) 'Has a SQL DEFAULT.',
      if (field.column.nullable) 'Nullable.',
      if (_createIsTriState(field)) 'Field.absent() uses the DEFAULT; Field.value(null) writes NULL.',
      if (field.type.note != null) field.type.note!,
    ];
    for (final note in notes) {
      out.writeln('  /// $note');
    }
    out.writeln('  final ${_createFieldType(field)} ${field.dartName};');
  }
  out.writeln();

  // toAssignments: converts to MssqlWriteAssignments for the write engine.
  out.writeln('  /// Builds the write assignments for [MssqlRepository.insert].');
  out.writeln('  MssqlWriteAssignments toAssignments(');
  out.writeln('      MssqlTableBinding<Object?> binding) {');
  out.writeln('    final values = <String, MssqlWriteValue>{};');
  for (final field in createFields) {
    final col = field.column.name;
    final dart = field.dartName;
    final literal = dartStringLiteral(col);
    if (_createIsRequired(field)) {
      out.writeln(
        '    values[$literal] = '
        'MssqlBoundValue(binding.column($literal)!.bind($dart));',
      );
      continue;
    }
    if (_createIsTriState(field)) {
      out.writeln('    if ($dart.isPresent) {');
      out.writeln(
        '      values[$literal] = '
        'MssqlBoundValue(binding.column($literal)!.bind($dart.value));',
      );
      out.writeln('    }');
      continue;
    }
    // Not null with a default: null omits the column. Nullable without one:
    // omitting and nulling are the same write, so binding is equivalent.
    out.writeln('    if ($dart != null || binding.column($literal)!.nullable) {');
    out.writeln(
      '      values[$literal] = '
      'MssqlBoundValue(binding.column($literal)!.bind($dart));',
    );
    out.writeln('    }');
  }
  out.writeln('    return MssqlWriteAssignments(values);');
  out.writeln('  }');
  out.writeln();

  // Equality
  out.writeln('  @override');
  out.writeln('  bool operator ==(Object other) =>');
  out.writeln('      identical(this, other) ||');
  out.write('      other is $name');
  for (final field in createFields) {
    out.write(' && other.${field.dartName} == ${field.dartName}');
  }
  out.writeln(';');
  out.writeln();
  out.writeln('  @override');
  out.write('  int get hashCode => Object.hashAll(<Object?>[');
  out.write(createFields.map((f) => f.dartName).join(', '));
  out.writeln(']);');
  out.writeln();
  out.writeln('  @override');
  out.write("  String toString() => '$name(");
  out.write(_toStringBody(createFields));
  out.writeln(")';");
  out.writeln('}');
}

/// Emits the Patch model: a partial update where absent, null and value
/// are three different things.
void _emitPatchClass(StringBuffer out, TablePlan plan) {
  final name = '${plan.rowBase}Patch';
  final patchFields = plan.fields.where((f) {
    // Patch excludes PK, identity, computed, rowversion and read-only.
    if (!f.writable) return false;
    final col = f.column.name.toLowerCase();
    final pk = plan.table.primaryKey?.columns ?? const <String>[];
    if (pk.any((k) => k.toLowerCase() == col)) return false;
    return true;
  }).toList();

  if (patchFields.isEmpty) {
    out.writeln('/// An empty patch: ${plan.table.qualifiedName} has no');
    out.writeln('/// writable non-key columns.');
    out.writeln('@immutable');
    out.writeln('class $name {');
    out.writeln('  const $name();');
    out.writeln();
    out.writeln('  MssqlWriteAssignments toAssignments(');
    out.writeln('      MssqlTableBinding<Object?> binding) =>');
    out.writeln('      MssqlWriteAssignments.empty;');
    out.writeln();
    out.writeln('  @override');
    out.writeln(
      '  bool operator ==(Object other) =>'
      ' other is $name;',
    );
    out.writeln();
    out.writeln('  @override');
    // `runtimeType.hashCode`, not `$name.hashCode`: the latter is static
    // access to an instance member and does not compile. Every instance of
    // an empty value class is equal to every other, so one constant hash for
    // the type is exactly right.
    out.writeln('  int get hashCode => runtimeType.hashCode;');
    out.writeln();
    out.writeln('  @override');
    out.writeln("  String toString() => '$name()';");
    out.writeln('}');
    return;
  }

  out.writeln('/// A partial update of ${plan.table.qualifiedName}.');
  out.writeln('///');
  out.writeln('/// Each field is a [Field]: [Field.absent] means "don\'t');
  out.writeln('/// touch", [Field.value] means "set to this". A nullable');
  out.writeln('/// column accepts `Field<T?>.value(null)` to clear it;');
  out.writeln('/// a non-null column\'s `Field<T>` cannot carry null.');
  out.writeln('@immutable');
  out.writeln('class $name {');
  out.write('  const $name({');
  for (final field in patchFields) {
    out.write('this.${field.dartName} = const Field.absent(), ');
  }
  out.writeln('});');
  out.writeln();

  for (final field in patchFields) {
    final fieldType = field.nullable ? 'Field<${field.type.name}?>' : 'Field<${field.type.name}>';
    final notes = <String>[if (field.column.nullable) 'Nullable.', if (field.type.note != null) field.type.note!];
    for (final note in notes) {
      out.writeln('  /// $note');
    }
    out.writeln('  final $fieldType ${field.dartName};');
  }
  out.writeln();

  // toAssignments
  out.writeln(
    '  /// Builds the write assignments for'
    ' [MssqlRepository.update] / [MssqlRepository.updateWhere].',
  );
  out.writeln('  MssqlWriteAssignments toAssignments(');
  out.writeln('      MssqlTableBinding<Object?> binding) {');
  out.writeln('    final values = <String, MssqlWriteValue>{};');
  for (final field in patchFields) {
    final col = field.column.name;
    final dart = field.dartName;
    out.writeln('    if ($dart.isPresent) {');
    out.writeln(
      '      values[${dartStringLiteral(col)}] = '
      'MssqlBoundValue(binding.column(${dartStringLiteral(col)})!.bind($dart.value));',
    );
    out.writeln('    }');
  }
  out.writeln('    return MssqlWriteAssignments(values);');
  out.writeln('  }');
  out.writeln();

  // Equality
  out.writeln('  @override');
  out.writeln('  bool operator ==(Object other) =>');
  out.writeln('      identical(this, other) ||');
  out.write('      other is $name');
  for (final field in patchFields) {
    out.write(' && other.${field.dartName} == ${field.dartName}');
  }
  out.writeln(';');
  out.writeln();
  out.writeln('  @override');
  out.write('  int get hashCode => Object.hashAll(<Object?>[');
  out.write(patchFields.map((f) => f.dartName).join(', '));
  out.writeln(']);');
  out.writeln();
  out.writeln('  @override');
  out.write("  String toString() => '$name(");
  out.write(_toStringBody(patchFields));
  out.writeln(")';");
  out.writeln('}');
}

String _toSqlExpression(FieldPlan field) {
  final name = field.dartName;
  switch (field.type.name) {
    case 'DateTime':
      return field.nullable
          ? '$name == null ? null : MssqlValue.dateTime2($name, scale: ${field.column.scale})'
          : 'MssqlValue.dateTime2($name, scale: ${field.column.scale})';
    case 'Duration':
      // The driver takes a time as a date-time value; the date part is ignored.
      return field.nullable
          ? '$name == null ? null : MssqlValue.time(DateTime(1900).add($name!), scale: ${field.column.scale})'
          : 'MssqlValue.time(DateTime(1900).add($name), scale: ${field.column.scale})';
    default:
      return name;
  }
}

void _emitJson(StringBuffer out, TablePlan plan, String concrete) {
  final visible = plan.fields.where((f) => !f.hidden).toList();
  out.writeln('  /// Keys are Dart field names, so renaming a field renames');
  out.writeln('  /// the JSON key with it rather than keeping two vocabularies.');
  out.writeln('  Map<String, Object?> toJson() => <String, Object?>{');
  for (final field in visible) {
    out.writeln("    '${field.dartName}': ${_toJsonExpression(field)},");
  }
  out.writeln('  };');
  out.writeln();
}

String _toJsonExpression(FieldPlan field) {
  final name = field.dartName;
  final bang = field.nullable ? '?' : '';
  return switch (field.type.name) {
    'DateTime' => '$name$bang.toIso8601String()',
    'Duration' => '$name$bang.inMicroseconds',
    // The null check narrows the local, not the field, so the encode still
    // needs the assertion.
    'Uint8List' => field.nullable ? '$name == null ? null : base64Encode($name!)' : 'base64Encode($name)',
    'MssqlDateTimeValue' => '$name$bang.toString()',
    _ => name,
  };
}

void _emitKeyClass(StringBuffer out, TablePlan plan) {
  final name = plan.keyType;
  out.writeln('/// The composite primary key of ${plan.table.qualifiedName}.');
  out.writeln('@immutable');
  out.writeln('class $name {');
  out.write('  const $name({');
  for (final field in plan.keyFields) {
    out.write('required this.${field.dartName}, ');
  }
  out.writeln('});');
  for (final field in plan.keyFields) {
    out.writeln('  final ${field.declaredType} ${field.dartName};');
  }
  out.writeln();
  out.writeln('  Map<String, Object?> toColumns() => <String, Object?>{');
  for (final field in plan.keyFields) {
    out.writeln('    ${dartStringLiteral(field.column.name)}: ${field.dartName},');
  }
  out.writeln('  };');
  out.writeln();
  out.writeln('  @override');
  out.writeln('  bool operator ==(Object other) =>');
  out.write('      other is $name');
  for (final field in plan.keyFields) {
    out.write(' && other.${field.dartName} == ${field.dartName}');
  }
  out.writeln(';');
  out.writeln();
  out.writeln('  @override');
  out.write('  int get hashCode => Object.hashAll(<Object?>[');
  out.write(plan.keyFields.map((f) => f.dartName).join(', '));
  out.writeln(']);');
  out.writeln('}');
}

void _emitRepositoryClass(StringBuffer out, TablePlan plan) {
  final name = plan.repositoryBase;
  final row = plan.rowClass;

  out.writeln('/// Reads and writes ${plan.table.qualifiedName}.');
  if (plan.readOnly) {
    out.writeln('///');
    out.writeln(
      '/// ${plan.table.isView ? 'A view' : 'This table'} has no primary key, '
      'so the key-addressed',
    );
    out.writeln('/// methods are not available: nothing identifies one row.');
  }
  out.writeln('class $name extends MssqlRepository<$row, ${plan.keyType}> {');
  if (plan.compositeKey) {
    out.writeln('  /// [schema] and [table] point this repository at another');
    out.writeln('  /// table of the same shape — Eloquent\'s `\$table`.');
    out.writeln(
      '  $name(MssqlSession session, '
      '{MssqlDialect? dialect, String? schema, String? table})',
    );
    out.writeln('    : super.withKeyValues(');
    out.writeln('        session,');
    out.writeln('        binding: tableBinding,');
    out.writeln('        keyValues: (key) => key.toColumns(),');
    out.writeln('        dialect: dialect,');
    out.writeln('        schema: schema,');
    out.writeln('        table: table,');
    out.writeln('      );');
  } else {
    out.writeln('  /// [schema] and [table] point this repository at another');
    out.writeln('  /// table of the same shape — Eloquent\'s `\$table`.');
    out.writeln(
      '  $name(super.session, '
      '{super.dialect, super.schema, super.table})',
    );
    out.writeln('    : super(binding: tableBinding);');
  }
  out.writeln();
  out.writeln('  /// Named tableBinding rather than binding: a static cannot');
  out.writeln('  /// share a name with an inherited instance member.');
  out.writeln('  static final MssqlTableBinding<$row> tableBinding =');
  out.writeln('      MssqlTableBinding<$row>(');
  out.writeln('    schema: ${dartStringLiteral(plan.table.schema)},');
  out.writeln('    table: ${dartStringLiteral(plan.table.name)},');
  out.write('    primaryKey: const <String>[');
  out.write((plan.table.primaryKey?.columns ?? const <String>[]).map((c) => "'$c'").join(', '));
  out.writeln('],');
  final identity = plan.table.identityColumn;
  out.writeln(
    identity == null ? '    identityColumn: null,' : '    identityColumn: ${dartStringLiteral(identity.name)},',
  );
  out.writeln('    insertStrategy: MssqlInsertStrategy.${plan.strategy.name},');
  out.writeln(
    '    decimalMode: MssqlDecimalMode.'
    '${plan.config.decimalMode.name},',
  );
  out.writeln('    schemaFingerprint: ${dartStringLiteral(plan.fingerprint)},');
  out.writeln('    apiVersion: ${MssqlApiVersion.current},');
  if (plan.softDeleteColumn != null) {
    out.writeln(
      '    softDelete: const MssqlSoftDelete('
      'column: ${dartStringLiteral(plan.softDeleteColumn!)}),',
    );
  }
  final timestamps = plan.timestampColumns;
  if (timestamps != null) {
    out.writeln('    timestamps: const MssqlTimestamps(');
    if (timestamps.createdColumn != null) {
      out.writeln(
        '      createdColumn: '
        '${dartStringLiteral(timestamps.createdColumn!)},',
      );
    }
    if (timestamps.updatedColumn != null) {
      out.writeln(
        '      updatedColumn: '
        '${dartStringLiteral(timestamps.updatedColumn!)},',
      );
    }
    out.writeln('    ),');
  }
  out.writeln('    columns: <MssqlBoundColumn>[');
  for (final field in plan.fields) {
    final c = field.column;
    out.writeln('      MssqlBoundColumn(');
    out.writeln('        name: ${dartStringLiteral(c.name)},');
    out.writeln('        type: MssqlType.${c.type.name},');
    if (c.nullable) out.writeln('        nullable: true,');
    if (c.isIdentity) out.writeln('        isIdentity: true,');
    if (c.isComputed) out.writeln('        isComputed: true,');
    if (c.isRowVersion) out.writeln('        isRowVersion: true,');
    if (c.hasDefault) out.writeln('        hasDefault: true,');
    if (field.readOnly) out.writeln('        isReadOnly: true,');
    out.writeln('        maxLength: ${c.maxLength},');
    out.writeln('        precision: ${c.precision},');
    out.writeln('        scale: ${c.scale},');
    out.writeln('      ),');
  }
  out.writeln('    ],');
  out.writeln('    fromRow: ${plan.rowBase}.fromRow,');
  out.writeln('    toColumns: (row) => row.toColumns(),');
  out.writeln('    readColumn: (row, name) => row.columnValue(name),');
  if (plan.hasRelations) {
    out.writeln('    applyRelations: (row, relations) => row.withRelations(relations),');
    out.writeln('    isRelationLoaded: (row, name) => row.isLoaded(name),');
  }
  if (plan.strategy == MssqlInsertStrategy.scopeIdentity && plan.identityField != null) {
    final field = plan.identityField!;
    out.writeln(
      '    applyIdentity: (row, id) => '
      'row.copyWith(${field.dartName}: (id! as num).toInt()),',
    );
  }
  out.writeln('  );');
  out.writeln('}');
}

/// Writes the file you own, created once and never touched again.
String emitScaffold(TablePlan plan) {
  final out = StringBuffer();
  out.writeln('// Created once by mssql_orm_dev and never rewritten.');
  out.writeln('// This file is yours: put application queries and behaviour here.');
  out.writeln('//');
  out.writeln('// The generated half lives in ../generated/${plan.fileName}.g.dart');
  out.writeln('// and is replaced on every run.');
  out.writeln();
  out.writeln("import '../generated/${plan.fileName}.g.dart';");
  out.writeln();
  // Re-exported so one import per table is enough: this file gives the row,
  // repository, typed columns and relations together, without a call site
  // importing the generated half.
  out.writeln("export '../generated/${plan.fileName}.g.dart';");
  out.writeln();
  out.writeln('class ${plan.rowClass} extends ${plan.rowBase} {');
  out.write('  const ${plan.rowClass}({');
  for (final field in plan.fields) {
    out.write(field.nullable ? 'super.${field.dartName}, ' : 'required super.${field.dartName}, ');
  }
  for (final relation in plan.relations) {
    out.write('super.${relation.name}, ');
  }
  if (plan.hasRelations) {
    out.write('super.loadedRelations, ');
    out.write('super.truncatedRelations, ');
  }
  out.writeln('});');
  out.writeln('}');
  out.writeln();
  out.writeln('class ${plan.repositoryClass} extends ${plan.repositoryBase} {');
  out.writeln(
    '  ${plan.repositoryClass}(super.session, '
    '{super.dialect, super.schema, super.table});',
  );
  out.writeln();
  out.writeln('  // To read a different table of the same shape');
  out.writeln('  //');
  out.writeln(
    "  //   ${plan.repositoryClass}(super.session) "
    ": super(table: '${plan.table.name}_Archive');",
  );
  out.writeln();
  out.writeln('  // Application queries go here, for example:');
  out.writeln('  //');
  out.writeln('  //   Future<List<${plan.rowClass}>> search(String term) =>');
  out.writeln(
    '  //       findWhere(${plan.columnsClass}.'
    '${plan.fields.first.dartName}.like(term));',
  );
  out.writeln('}');
  return out.toString();
}

/// `OrdersRel.customer`, `OrdersRel.lines`: the relations a caller passes to
/// `include:`.
void _emitRelationsClass(StringBuffer out, TablePlan plan) {
  out.writeln('/// Relations of ${plan.table.qualifiedName}, from its foreign');
  out.writeln('/// keys. Pass these to `include:` to load them eagerly.');
  out.writeln('abstract final class ${plan.columnsClass}Rel {');
  for (final relation in plan.relations) {
    final targetRow = _generatedRowClass(plan.config, relation.target);
    final targetRepo = _generatedRepositoryClass(plan.config, relation.target);
    out.writeln(
      '  static MssqlRelation<${plan.rowClass}, $targetRow> '
      'get ${relation.name} =>',
    );
    out.writeln('      MssqlRelation<${plan.rowClass}, $targetRow>(');
    out.writeln("        name: '${relation.name}',");
    out.writeln('        kind: MssqlRelationKind.${relation.kind.name},');
    out.writeln(
      '        targetBinding: $targetRepo'
      '${plan.scaffold ? 'Base' : ''}.tableBinding,',
    );
    out.write('        localColumns: const <String>[');
    out.write(relation.localColumns.map((c) => "'$c'").join(', '));
    out.writeln('],');
    out.write('        foreignColumns: const <String>[');
    out.write(relation.foreignColumns.map((c) => "'$c'").join(', '));
    out.writeln('],');
    if (relation.through != null) {
      final through = relation.through!;
      final throughRepo = _generatedRepositoryClass(plan.config, through.bindingTable);
      out.writeln('        through: MssqlRelationThrough(');
      out.writeln(
        '          binding: $throughRepo'
        '${plan.scaffold ? 'Base' : ''}.tableBinding.erase(),',
      );
      out.write('          nearColumns: const <String>[');
      out.write(through.nearColumns.map((c) => "'$c'").join(', '));
      out.writeln('],');
      out.write('          farColumns: const <String>[');
      out.write(through.farColumns.map((c) => "'$c'").join(', '));
      out.writeln('],');
      if (through.typeColumn != null) {
        out.writeln('          typeColumn: ${dartStringLiteral(through.typeColumn!)},');
      }
      if (through.typeValue != null) {
        out.writeln('          typeValue: ${dartStringLiteral(through.typeValue!)},');
      }
      out.writeln('        ),');
    }
    if (relation.morph != null) {
      final morph = relation.morph!;
      out.writeln('        morph: MssqlMorph(');
      out.writeln('          typeColumn: ${dartStringLiteral(morph.typeColumn)},');
      out.writeln('          idColumn: ${dartStringLiteral(morph.idColumn)},');
      if (morph.typeValue != null) {
        out.writeln('          typeValue: ${dartStringLiteral(morph.typeValue!)},');
      }
      out.writeln('          unknown: MssqlMorphUnknown.${morph.unknown.name},');
      if (morph.targets.isNotEmpty) {
        out.writeln('          targets: <String, MssqlTableBinding<Object?>>{');
        final keys = morph.targets.keys.toList()..sort();
        for (final key in keys) {
          final target = morph.targets[key]!;
          final repo = _generatedRepositoryClass(plan.config, target);
          out.writeln(
            '            ${dartStringLiteral(key)}: $repo'
            '${plan.scaffold ? 'Base' : ''}.tableBinding.erase(),',
          );
        }
        out.writeln('          },');
      }
      out.writeln('        ),');
    }
    out.writeln('      );');
  }
  out.writeln('}');
  for (final relation in plan.relations) {
    _emitRelationIncludeExtension(out, plan, relation);
  }
}

void _emitRelationIncludeExtension(StringBuffer out, TablePlan plan, RelationPlan relation) {
  final targetRow = _generatedRowClass(plan.config, relation.target);
  final targetFields = _generatedFieldsClass(plan.config, relation.target);
  final ext = '${plan.columnsClass}${_pascal(relation.name)}Include';
  out.writeln();
  out.writeln('/// Typed include modifiers for ${plan.rowClass}.${relation.name}.');
  out.writeln('extension $ext on MssqlRelation<${plan.rowClass}, $targetRow> {');
  out.writeln('  /// ANDs a predicate on the target row.');
  out.writeln('  MssqlRelation<${plan.rowClass}, $targetRow> where(');
  out.writeln('    MssqlCondition Function($targetFields fields) predicate,');
  out.writeln('  ) =>');
  out.writeln('      filtered(<MssqlCondition>[predicate(const $targetFields())]);');
  out.writeln();
  out.writeln('  /// Orders loaded children from target fields.');
  out.writeln('  MssqlRelation<${plan.rowClass}, $targetRow> orderBy(');
  out.writeln('    List<MssqlOrder> Function($targetFields fields) ordering,');
  out.writeln('  ) =>');
  out.writeln('      ordered(ordering(const $targetFields()));');
  out.writeln();
  out.writeln('  /// Nested includes of the target.');
  out.writeln('  MssqlRelation<${plan.rowClass}, $targetRow> include(');
  out.writeln('    Iterable<MssqlRelation<$targetRow, Object?>> Function(');
  out.writeln('      $targetFields fields,');
  out.writeln('    ) nested,');
  out.writeln('  ) =>');
  out.writeln('      withNested(nested(const $targetFields()));');
  out.writeln('}');
}

String _pascal(String name) => name.isEmpty ? name : '${name[0].toUpperCase()}${name.substring(1)}';

/// The Dart type a relation field holds: the row for a to-one, a list for a
/// to-many.
String _relationType(TablePlan plan, RelationPlan relation) {
  final row = _generatedRowClass(plan.config, relation.target);
  return relation.isToOne ? row : 'List<$row>';
}

/// `class_names` for [qualified], otherwise the table's own Pascal name.
String _generatedBaseName(GeneratorConfig config, String qualified) {
  final tableName = qualified.contains('.') ? qualified.split('.').last : qualified;
  return config.classNames[qualified] ?? className(tableName);
}

String _generatedRowClass(GeneratorConfig config, String qualified) => '${_generatedBaseName(config, qualified)}Row';

String _generatedFieldsClass(GeneratorConfig config, String qualified) =>
    '${_generatedBaseName(config, qualified)}Fields';

String _generatedRepositoryClass(GeneratorConfig config, String qualified) =>
    '${_generatedBaseName(config, qualified)}Repository';

/// Writes the generated `AppDatabase` class that aggregates every table.
///
/// Each table gets a lazy getter that returns a repository bound to the
/// database's session. Inside a transaction, the same getter on the
/// transaction-scoped database returns a repository over the transaction's
/// session, so every read and write in the callback goes to the same lease.
String emitDatabase(
  List<TablePlan> plans, {
  required String databaseClass,
  required String version,
  bool includeReports = false,
  bool includeProcedures = false,
}) {
  final out = StringBuffer();
  writeGenerationBanner(out, version: version);
  out.writeln();
  out.writeln("import 'package:mssql_native/mssql_native.dart';");
  out.writeln("import 'package:mssql_orm/orm.dart';");
  for (final plan in plans) {
    out.writeln("import '${plan.fileName}.g.dart';");
  }
  if (includeReports) {
    out.writeln("import 'queries.g.dart';");
  }
  if (includeProcedures) {
    out.writeln("import 'procedures.g.dart';");
  }
  out.writeln();
  out.writeln('/// The entry point for ORM access to the database.');
  out.writeln('///');
  out.writeln('/// Use [borrow], [withPool], or [open] to choose session ownership.');
  out.writeln('/// Queries created inside [transaction] use its session.');
  out.writeln('class $databaseClass extends MssqlAppDatabase<$databaseClass> {');
  out.writeln(
    '  $databaseClass(super.session, {super.clock, super.owned, '
    'super.pool, super.changes, super.capabilities, super.observer, '
    'super.observerOptions});',
  );
  out.writeln();
  out.writeln('  /// A connection the caller opened and closes.');
  out.writeln('  ///');
  out.writeln('  /// Accepts only a connection because this path supports transactions.');
  out.writeln('  // ignore: use_super_parameters');
  out.writeln('  $databaseClass.borrow(MssqlConnection connection)');
  out.writeln('      : super(connection);');
  out.writeln();
  out.writeln('  /// A pool the caller created and closes.');
  out.writeln('  ///');
  out.writeln('  /// Each statement takes a lease and gives it back;');
  out.writeln('  /// [transaction] holds one lease for the whole callback.');
  out.writeln('  $databaseClass.withPool(MssqlConnectionPool pool)');
  out.writeln('      : super(pool.session, pool: pool);');
  out.writeln();
  out.writeln('  /// Opens and owns a connection. [close] closes it.');
  out.writeln('  static Future<$databaseClass> open(');
  out.writeln('      MssqlConnectionConfig config) async {');
  out.writeln('    final connection = await MssqlConnection.open(config);');
  out.writeln('    return $databaseClass(connection, owned: true);');
  out.writeln('  }');
  out.writeln();
  out.writeln('  /// Opens and owns a pool. [close] closes it.');
  out.writeln('  static $databaseClass openPool(');
  out.writeln('      MssqlConnectionConfig config,');
  out.writeln('      {MssqlPoolConfig pool = const MssqlPoolConfig()}) {');
  out.writeln('    final created = MssqlConnectionPool(config, poolConfig: pool);');
  out.writeln(
    '    return $databaseClass(created.session, '
    'pool: created, owned: true);',
  );
  out.writeln('  }');
  out.writeln();
  out.writeln('  @override');
  out.writeln('  $databaseClass fork(MssqlSession session) =>');
  out.writeln(
    '      $databaseClass(session, clock: clock, changes: changes, '
    'capabilities: capabilities, observer: observer, '
    'observerOptions: observerOptions);',
  );
  out.writeln();
  for (final plan in plans) {
    out.writeln('  /// Reads and writes ${plan.table.qualifiedName}.');
    out.writeln('  ${plan.queryClass} get ${fieldName(plan.table.name)} =>');
    out.writeln(
      '      ${plan.queryClass}(contextFor('
      '${plan.repositoryBase}.tableBinding));',
    );
    out.writeln();
  }
  if (includeReports) {
    out.writeln('  /// Typed methods generated from `.sql` files.');
    out.writeln(
      '  ${databaseClass}Reports get reports => '
      '${databaseClass}Reports(this);',
    );
    out.writeln();
  }
  if (includeProcedures) {
    out.writeln('  /// Typed stored-procedure methods.');
    out.writeln(
      '  ${databaseClass}Procedures get procedures => '
      '${databaseClass}Procedures(this);',
    );
    out.writeln();
  }
  out.writeln('}');
  return out.toString();
}
