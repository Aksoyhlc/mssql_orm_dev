part of '../emitter.dart';

/// Names reserved by [MssqlEntityQuery] and generated query terminals.
///
/// Generation rejects a colliding `whereX` member before emitting an invalid
/// class.
const Set<String> _reservedQueryMembers = <String>{
  'where',
  'orderBy',
  'options',
  'withTrashed',
  'onlyTrashed',
  'withoutTrashed',
  'withoutScope',
  'withoutGlobalScopes',
  'withoutScopes',
  'rebuild',
  'get',
  'first',
  'firstOrFail',
  'single',
  'singleOrNull',
  'find',
  'getById',
  'fields',
  'context',
  'state',
  'binding',
  'session',
  'dialect',
  'scopeSelection',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'create',
  'update',
  'delete',
  'forceDelete',
  'restore',
  'include',
  'whereHas',
  'whereDoesntHave',
  'withWhereHas',
  'withCount',
  'withSum',
  'withAvg',
  'withMin',
  'withMax',
  'withExists',
  'withAggregates',
  'loadMissing',
  'getOrCreate',
  'updateValues',
  'related',
  'page',
  'count',
  'exists',
  'stream',
  'watch',
  'whereIf',
  'whereIfNotNull',
  'whereInIfNotEmpty',
  'search',
  'when',
  'thenBy',
  'createMany',
  'updateMany',
  'createGraph',
  'decrementQuantities',
  'createValues',
  'createManyValues',
  'updateManyKeyed',
  'createGraphValues',
  'orderByNamed',
  'ensureStableOrder',
  'cursorPage',
  'chunkById',
  'chunk',
  'lazy',
  'dropPageSentinel',
  'select',
  'select2',
  'select3',
  'select4',
};

void _validateQueryApi(TablePlan plan) {
  final used = <String, String>{};
  void claim(String dartName, String source) {
    final previous = used[dartName];
    if (previous != null) {
      throw ConfigError(
        '$source and $previous both become the generated member '
        '"$dartName" on ${plan.queryClass}. Rename one with field_names '
        'or query_methods. Nothing was written.',
      );
    }
    if (_reservedQueryMembers.contains(dartName)) {
      throw ConfigError(
        '$source becomes the generated member "$dartName", which collides '
        'with MssqlEntityQuery.$dartName. Rename the column with '
        'field_names, or set query_methods for that column. '
        'Nothing was written.',
      );
    }
    used[dartName] = source;
  }

  for (final field in plan.fields) {
    claim(
      plan.whereShortcut(field),
      '${plan.table.qualifiedName}.${field.column.name}',
    );
  }
  for (final relation in plan.relations) {
    claim(
      relation.name,
      '${plan.table.qualifiedName} relation ${relation.name}',
    );
    claim(
      '${relation.name}Of',
      '${plan.table.qualifiedName} relation ${relation.name} write handle',
    );
  }
  for (final key in _usableUniqueKeys(plan)) {
    final fields = _uniqueFields(plan, key);
    if (fields == null) continue;
    claim(
      'getOrCreateBy${fields.map((f) => _pascal(f.dartName)).join()}',
      '${plan.table.qualifiedName} unique ${key.name}',
    );
  }
}

void _validateRelationFields(TablePlan plan) {
  final columns = <String>{for (final f in plan.fields) f.dartName};
  for (final relation in plan.relations) {
    if (relation.name == mssqlTruncatedKeyName) {
      throw ConfigError(
        '${plan.table.qualifiedName} relation "${relation.name}" collides '
        'with the reserved truncated-metadata key. Rename it under '
        'relation_names. Nothing was written.',
      );
    }
    if (columns.contains(relation.name)) {
      throw ConfigError(
        '${plan.table.qualifiedName} relation "${relation.name}" collides '
        'with a column field of the same Dart name. Rename the relation or '
        'the column with relation_names / field_names. Nothing was written.',
      );
    }
  }
}

void _emitQueryClass(StringBuffer out, TablePlan plan) {
  final name = plan.queryClass;
  final row = plan.rowClass;
  final fields = plan.fieldsClass;
  out.writeln('/// Query over ${plan.table.qualifiedName}.');
  out.writeln('///');
  out.writeln('/// Every entity-preserving call returns [$name], so a user');
  out.writeln('/// extension (`extension on $name`) stays in the chain.');
  out.writeln('/// `whereX` shortcuts AND an equality; OR stays in');
  out.writeln('/// `where((o) => … | …)`.');
  out.writeln('class $name extends MssqlEntityQuery<$row, $fields, $name> {');
  out.writeln('  $name(super.context, [super.state, super.included]);');
  out.writeln();
  out.writeln('  @override');
  out.writeln('  /// Columns bound to whatever source this query has.');
  out.writeln('  ///');
  out.writeln('  /// The constant instance for the generated table, and a');
  out.writeln('  /// rebound one after `at(schema:, table:)`, so a');
  out.writeln('  /// predicate written after a rebind names the table this');
  out.writeln('  /// statement actually reads.');
  out.writeln('  $fields get fields =>');
  out.writeln('      binding.sourceRef == ${plan.columnsClass}.source');
  out.writeln('          ? const $fields()');
  out.writeln('          : $fields(binding.sourceRef);');
  out.writeln();
  out.writeln('  @override');
  out.writeln(
    '  $name recreate(MssqlQueryState state, '
    'List<MssqlRelation<$row, Object?>> included) =>',
  );
  out.writeln('      $name(context, state, included);');
  out.writeln();
  out.writeln('  @override');
  out.writeln(
    '  $name recreateAt(MssqlQueryContext<$row> context, '
    'MssqlQueryState state, '
    'List<MssqlRelation<$row, Object?>> included) =>',
  );
  out.writeln('      $name(context, state, included);');
  for (final field in plan.fields) {
    final method = plan.whereShortcut(field);
    out.writeln();
    _emitColumnDoc(out, plan, field);
    out.writeln('  ///');
    out.writeln(
      '  /// ANDs `${field.column.name} = @value`. The parameter is '
      'non-null',
    );
    out.writeln(
      '  /// even when the column is nullable: `= NULL` never matches, '
      'so',
    );
    out.writeln('  /// NULL uses `isNull` / `isNotNull` on the callback.');
    out.writeln('  $name $method(${field.type.name} value) =>');
    out.writeln(
      '      rebuild(state.where_(fields.${field.dartName}.eq(value)));',
    );
  }
  _emitOrderByNamed(out, plan);
  _emitHierarchy(out, plan);
  _emitRelationMutations(out, plan);
  _emitGetOrCreateMethods(out, plan);
  _emitPatchUpdate(out, plan);
  _emitCreateMethods(out, plan);
  if (plan.hasKey && !plan.compositeKey) {
    final key = plan.keyFields.single;
    out.writeln();
    out.writeln('  /// The row with this primary key, or null.');
    out.writeln(
      '  Future<$row?> find(${plan.keyType} key) => '
      '${plan.whereShortcut(key)}(key).first();',
    );
    out.writeln();
    out.writeln('  /// The row with this primary key, or not-found.');
    out.writeln(
      '  Future<$row> getById(${plan.keyType} key) => '
      '${plan.whereShortcut(key)}(key).firstOrFail();',
    );
  } else if (plan.hasKey && plan.compositeKey) {
    out.writeln();
    out.writeln('  /// The row with this primary key, or null.');
    out.writeln('  Future<$row?> find(${plan.keyType} key) =>');
    out.writeln('      rebuild(state.where_(_keyEquals(key))).first();');
    out.writeln();
    out.writeln('  /// The row with this primary key, or not-found.');
    out.writeln('  Future<$row> getById(${plan.keyType} key) =>');
    out.writeln('      rebuild(state.where_(_keyEquals(key))).firstOrFail();');
    out.writeln();
    out.writeln('  MssqlCondition _keyEquals(${plan.keyType} key) {');
    out.writeln('    return and(<MssqlCondition>[');
    for (final field in plan.keyFields) {
      out.writeln('      fields.${field.dartName}.eq(key.${field.dartName}),');
    }
    out.writeln('    ]);');
    out.writeln('  }');
  }
  out.writeln('}');
}

List<MssqlUniqueKeySchema> _usableUniqueKeys(TablePlan plan) =>
    <MssqlUniqueKeySchema>[
      for (final key in plan.table.uniqueKeys)
        if (key.guaranteesUniqueness && !key.isPrimaryKey) key,
    ];

List<FieldPlan>? _uniqueFields(TablePlan plan, MssqlUniqueKeySchema key) {
  final fields = <FieldPlan>[];
  for (final name in key.columns) {
    FieldPlan? found;
    for (final field in plan.fields) {
      if (field.column.name.toLowerCase() == name.toLowerCase()) {
        found = field;
        break;
      }
    }
    if (found == null) return null;
    fields.add(found);
  }
  return fields;
}

void _emitGetOrCreateMethods(StringBuffer out, TablePlan plan) {
  for (final key in _usableUniqueKeys(plan)) {
    final fields = _uniqueFields(plan, key);
    if (fields == null) continue;
    final method =
        'getOrCreateBy${fields.map((f) => _pascal(f.dartName)).join()}';
    final uniqueMethod = fields.length == 1
        ? fields.single.dartName
        : '${fields.first.dartName}'
              '${fields.skip(1).map((f) => _pascal(f.dartName)).join()}';
    final createFields = plan.fields.where((f) => f.writable).toList();
    out.writeln();
    out.writeln(
      '  /// Insert or return the live row with this unique '
      '${fields.map((f) => f.column.name).join(', ')}.',
    );
    out.writeln('  ///');
    out.writeln(
      '  /// Insert-first; a 2601/2627 on `${key.name}` reads the '
      'winner. A collision on a different unique key is rethrown.',
    );
    out.write('  Future<${plan.rowClass}> $method(');
    for (final field in fields) {
      out.write('${field.type.name} ${field.dartName}, ');
    }
    out.writeln('{');
    for (final field in createFields) {
      if (fields.any(
        (k) => k.column.name.toLowerCase() == field.column.name.toLowerCase(),
      )) {
        continue;
      }
      final required = !field.nullable && !field.column.hasDefault;
      final type = required ? field.type.name : '${field.type.name}?';
      out.writeln(
        required
            ? '    required ${field.type.name} ${field.dartName},'
            : '    $type ${field.dartName},',
      );
    }
    out.writeln('    bool restoreExisting = false,');
    out.writeln('    bool includeDeleted = false,');
    out.writeln('  }) {');
    out.writeln('    return getOrCreate(');
    out.write('      key: ${plan.columnsClass}Unique.$uniqueMethod(');
    out.write(fields.map((f) => f.dartName).join(', '));
    out.writeln('),');
    out.write('      create: ${plan.rowBase}Create(');
    for (final field in createFields) {
      out.write('${field.dartName}: ${field.dartName}, ');
    }
    out.writeln(').toAssignments(binding.erase()),');
    out.writeln('      restoreExisting: restoreExisting,');
    out.writeln('      includeDeleted: includeDeleted,');
    out.writeln('    );');
    out.writeln('  }');
  }
}

void _emitPatchUpdate(StringBuffer out, TablePlan plan) {
  out.writeln();
  out.writeln('  /// Partial update of matching rows.');
  out.writeln('  ///');
  out.writeln(
    '  /// Absent patch fields are not named. [expectedVersion] is '
    'the rowversion token; a table without one refuses it.',
  );
  out.writeln('  Future<int> update(');
  out.writeln('    ${plan.rowBase}Patch patch, {');
  out.writeln('    Object? expectedVersion,');
  out.writeln('    int? expectAffected,');
  out.writeln('  }) =>');
  out.writeln('      updateValues(');
  out.writeln('        patch.toAssignments(binding.erase()),');
  out.writeln('        expectedVersion: expectedVersion,');
  out.writeln('        expectAffected: expectAffected,');
  out.writeln('      );');
}

String _targetCreateClass(TablePlan plan, RelationPlan relation) {
  final qualified = relation.target;
  final tableName = qualified.contains('.')
      ? qualified.split('.').last
      : qualified;
  final base = plan.config.classNames[qualified] ?? className(tableName);
  final row = '${base}Row';
  final rowBase = plan.scaffold ? '${row}Base' : row;
  return '${rowBase}Create';
}

bool _graphRelation(RelationPlan relation) {
  switch (relation.kind) {
    case MssqlRelationKind.belongsTo:
    case MssqlRelationKind.hasOne:
    case MssqlRelationKind.hasMany:
    case MssqlRelationKind.belongsToMany:
    case MssqlRelationKind.morphOne:
    case MssqlRelationKind.morphMany:
    case MssqlRelationKind.morphToMany:
      return true;
    case MssqlRelationKind.morphTo:
    case MssqlRelationKind.hasOneThrough:
    case MssqlRelationKind.hasManyThrough:
      return false;
  }
}

bool _graphRelationToOne(RelationPlan relation) =>
    relation.kind == MssqlRelationKind.belongsTo ||
    relation.kind == MssqlRelationKind.hasOne ||
    relation.kind == MssqlRelationKind.morphOne;

void _emitCreateMethods(StringBuffer out, TablePlan plan) {
  if (plan.table.isView) return;
  final create = '${plan.rowBase}Create';
  out.writeln();
  out.writeln('  /// Inserts [input] and returns the stored row.');
  out.writeln('  ///');
  out.writeln(
    '  /// Absent fields become SQL DEFAULT. Binding null would '
    'overwrite the default.',
  );
  out.writeln('  Future<${plan.rowClass}> create($create input) =>');
  out.writeln('      createValues(input.toAssignments(binding.erase()));');
  out.writeln();
  out.writeln('  /// Batched insert. Never switches to BCP on its own.');
  out.writeln('  Future<MssqlCreateManyResult<${plan.rowClass}>> createMany(');
  out.writeln('    List<$create> rows, {');
  out.writeln(
    '    MssqlCreateManyStrategy strategy = '
    'MssqlCreateManyStrategy.insertValues,',
  );
  out.writeln('    MssqlBulkOptions bulk = const MssqlBulkOptions(),');
  out.writeln('    bool atomic = true,');
  out.writeln('    bool returnRows = true,');
  out.writeln('  }) =>');
  out.writeln('      createManyValues(');
  out.writeln(
    '        <MssqlWriteAssignments>[for (final row in rows) '
    'row.toAssignments(binding.erase())],',
  );
  out.writeln('        strategy: strategy,');
  out.writeln('        bulk: bulk,');
  out.writeln('        atomic: atomic,');
  out.writeln('        returnRows: returnRows,');
  out.writeln('      );');
  if (plan.hasKey && !plan.compositeKey) {
    final key = plan.keyFields.single;
    out.writeln();
    out.writeln('  /// Staging JOIN update keyed by ${key.column.name}.');
    out.writeln('  Future<int> updateMany(');
    out.writeln('    Map<${plan.keyType}, ${plan.rowBase}Patch> byKey, {');
    out.writeln('    int? expectAffected,');
    out.writeln('  }) =>');
    out.writeln('      updateManyKeyed(');
    out.writeln('        <MssqlKeyedPatch>[');
    out.writeln('          for (final entry in byKey.entries)');
    out.writeln('            MssqlKeyedPatch(');
    out.writeln(
      '              key: <String, Object?>{'
      '${dartStringLiteral(key.column.name)}: entry.key},',
    );
    out.writeln(
      '              patch: entry.value.toAssignments(binding.erase()),',
    );
    out.writeln('            ),');
    out.writeln('        ],');
    out.writeln('        expectAffected: expectAffected,');
    out.writeln('      );');
  } else if (plan.hasKey && plan.compositeKey) {
    out.writeln();
    out.writeln('  /// Staging JOIN update keyed by the primary key.');
    out.writeln('  Future<int> updateMany(');
    out.writeln(
      '    List<({${plan.keyType} key, ${plan.rowBase}Patch patch})> '
      'rows, {',
    );
    out.writeln('    int? expectAffected,');
    out.writeln('  }) =>');
    out.writeln('      updateManyKeyed(');
    out.writeln('        <MssqlKeyedPatch>[');
    out.writeln('          for (final row in rows)');
    out.writeln('            MssqlKeyedPatch(');
    out.writeln('              key: <String, Object?>{');
    for (final field in plan.keyFields) {
      out.writeln(
        '                ${dartStringLiteral(field.column.name)}: '
        'row.key.${field.dartName},',
      );
    }
    out.writeln('              },');
    out.writeln(
      '              patch: row.patch.toAssignments(binding.erase()),',
    );
    out.writeln('            ),');
    out.writeln('        ],');
    out.writeln('        expectAffected: expectAffected,');
    out.writeln('      );');
  }
  final graphRelations = plan.relations.where(_graphRelation).toList();
  out.writeln();
  out.writeln('  /// Explicit graph insert in one transaction.');
  out.writeln('  ///');
  out.writeln(
    '  /// Only the named relations are written. There is no cascade '
    'delete.',
  );
  out.write('  Future<${plan.rowClass}> createGraph(');
  out.writeln('$create input, {');
  for (final relation in graphRelations) {
    final childCreate = _targetCreateClass(plan, relation);
    if (_graphRelationToOne(relation)) {
      out.writeln('    $childCreate? ${relation.name},');
    } else {
      out.writeln('    List<$childCreate>? ${relation.name},');
    }
  }
  out.writeln('    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,');
  out.writeln('  }) {');
  for (final relation in graphRelations) {
    out.writeln('    final ${relation.name}Input = ${relation.name};');
  }
  out.writeln('    return createGraphValues(');
  out.writeln('      MssqlGraphInsert(');
  out.writeln('        input.toAssignments(binding.erase()),');
  out.writeln('        related: <MssqlGraphRelation>[');
  for (final relation in graphRelations) {
    if (_graphRelationToOne(relation)) {
      out.writeln('          if (${relation.name}Input != null)');
      out.writeln('            MssqlGraphRelation(');
      out.writeln('              fields.${relation.name}.asInclude,');
      out.writeln('              <MssqlGraphInsert<Object?>>[');
      out.writeln('                MssqlGraphInsert(');
      out.writeln(
        '                  ${relation.name}Input.toAssignments('
        'fields.${relation.name}.targetBinding.erase()),',
      );
      out.writeln('                ),');
      out.writeln('              ],');
      out.writeln('            ),');
    } else {
      out.writeln('          if (${relation.name}Input != null)');
      out.writeln('            MssqlGraphRelation(');
      out.writeln('              fields.${relation.name}.asInclude,');
      out.writeln('              <MssqlGraphInsert<Object?>>[');
      out.writeln('                for (final item in ${relation.name}Input)');
      out.writeln('                  MssqlGraphInsert(');
      out.writeln(
        '                    item.toAssignments('
        'fields.${relation.name}.targetBinding.erase()),',
      );
      out.writeln('                  ),');
      out.writeln('              ],');
      out.writeln('            ),');
    }
  }
  out.writeln('        ],');
  out.writeln('      ),');
  out.writeln('      cycle: cycleWrite,');
  out.writeln('    );');
  out.writeln('  }');
}

void _emitUniqueClass(StringBuffer out, TablePlan plan) {
  final keys = <({MssqlUniqueKeySchema key, List<FieldPlan> fields})>[
    for (final key in _usableUniqueKeys(plan))
      if (_uniqueFields(plan, key) != null)
        (key: key, fields: _uniqueFields(plan, key)!),
  ];
  if (keys.isEmpty) return;
  out.writeln(
    '/// Unique keys of ${plan.table.qualifiedName} that getOrCreate '
    'may use.',
  );
  out.writeln('///');
  out.writeln(
    '/// Filtered and disabled indexes are omitted: they do not '
    'make a row unique across the table.',
  );
  out.writeln('abstract final class ${plan.columnsClass}Unique {');
  for (final item in keys) {
    final fields = item.fields;
    final method = fields.length == 1
        ? fields.single.dartName
        : '${fields.first.dartName}'
              '${fields.skip(1).map((f) => _pascal(f.dartName)).join()}';
    out.writeln();
    out.writeln(
      '  /// `${item.key.name}` on '
      '${fields.map((f) => f.column.name).join(', ')}.',
    );
    out.write('  static MssqlUniqueMatch $method(');
    out.write(fields.map((f) => '${f.type.name} ${f.dartName}').join(', '));
    out.writeln(') =>');
    out.writeln('      MssqlUniqueMatch(');
    out.writeln('        indexName: ${dartStringLiteral(item.key.name)},');
    out.writeln('        values: <String, Object?>{');
    for (final field in fields) {
      out.writeln(
        '          ${dartStringLiteral(field.column.name)}: '
        '${field.dartName},',
      );
    }
    out.writeln('        },');
    out.writeln('      );');
  }
  out.writeln('}');
}

void _emitRelationMutations(StringBuffer out, TablePlan plan) {
  for (final relation in plan.relations) {
    final targetRow = _generatedRowClass(plan.config, relation.target);
    final method = '${relation.name}Of';
    out.writeln();
    out.writeln('  /// Writes against `${relation.name}` of [parent].');
    out.writeln('  ///');
    out.writeln(
      '  /// Same object as `related(parent, (f) => f.${relation.name})`.',
    );
    out.writeln(
      '  /// create/associate/attach never cascade-delete the other side.',
    );
    out.writeln(
      '  MssqlRelationMutation<${plan.rowClass}, $targetRow> '
      '$method(${plan.rowClass} parent) =>',
    );
    out.writeln('      related(parent, (f) => f.${relation.name});');
  }
}

void _emitOrderByNamed(StringBuffer out, TablePlan plan) {
  out.writeln();
  out.writeln('  /// UI sort: [column] must be a field of this table.');
  out.writeln('  ///');
  out.writeln('  /// A string from a query-string is not passed to SQL. The');
  out.writeln('  /// allowlist is the generated fields; anything else is an');
  out.writeln('  /// [ArgumentError] naming the legal keys.');
  out.writeln('  ${plan.queryClass} orderByNamed(');
  out.writeln('    String column, {');
  out.writeln('    bool descending = false,');
  out.writeln('  }) {');
  out.writeln('    switch (column) {');
  for (final field in plan.fields) {
    out.writeln('      case ${dartStringLiteral(field.dartName)}:');
    out.writeln('      case ${dartStringLiteral(field.column.name)}:');
    out.writeln(
      '        return orderBy((o) => <MssqlOrder>['
      'descending ? o.${field.dartName}.desc() '
      ': o.${field.dartName}.asc()]);',
    );
  }
  out.writeln('      default:');
  out.writeln('        throw ArgumentError.value(');
  out.writeln('          column,');
  out.writeln("          'column',");
  out.writeln(
    "          '${plan.queryClass} cannot sort by \"\$column\". "
    "Allowed: ${plan.fields.map((f) => f.dartName).join(', ')}.',",
  );
  out.writeln('        );');
  out.writeln('    }');
  out.writeln('  }');
}

/// User-owned scope extension, written once and never overwritten.
String emitScopeScaffold(TablePlan plan) {
  final out = StringBuffer();
  out.writeln('// Created once by mssql_orm_dev and never rewritten.');
  out.writeln('// Named scopes live here so regeneration cannot delete them.');
  out.writeln('//');
  out.writeln('// Import this file from application code when you want the');
  out.writeln('// extension in scope. Generated barrels do not export it,');
  out.writeln('// because an empty extension is yours to grow.');
  out.writeln();
  out.writeln("import '../generated/${plan.fileName}.g.dart';");
  out.writeln();
  out.writeln('extension ${plan.columnsClass}Scopes on ${plan.queryClass} {');
  if (plan.fields.isNotEmpty) {
    out.writeln(
      '  // ${plan.queryClass} open() => '
      '${plan.whereShortcut(plan.fields.first)}(/* value */);',
    );
  }
  out.writeln('}');
  return out.toString();
}

/// Emits `descendantsOf` when the table walks itself through one self-FK.
///
/// A filter, not a separate query type: the recursive expression is declared
/// on this query's statement and the rows are narrowed to the keys it walked,
/// so scopes, ordering, includes and paging all still apply and the result is
/// the same [TablePlan.queryClass] every other call returns.
void _emitHierarchy(StringBuffer out, TablePlan plan) {
  final parent = plan.hierarchyParentField;
  final key = plan.keyField;
  if (parent == null || key == null) return;
  final name = plan.queryClass;
  final keyType = key.type.name;
  final cteName = '${fieldName(plan.table.name)}_descendants';
  out.writeln();
  out.writeln('  /// The recursive walk of ${plan.table.qualifiedName}');
  out.writeln('  /// down ${parent.column.name}, as a reusable expression.');
  out.writeln('  static MssqlHierarchy<$keyType> get hierarchy =>');
  out.writeln('      MssqlHierarchy<$keyType>(');
  out.writeln(
    '        tableParts: ${plan.repositoryBase}.tableBinding'
    '.nameParts,',
  );
  out.writeln('        key: const ${plan.fieldsClass}().${key.dartName},');
  out.writeln(
    '        parentKey: const ${plan.fieldsClass}()'
    '.${parent.dartName},',
  );
  out.writeln("        name: '$cteName',");
  out.writeln('      );');
  out.writeln();
  out.writeln('  /// Rows under [root], following ${parent.column.name}.');
  out.writeln('  ///');
  out.writeln('  /// [maxDepth] limits returned generations; [maxRecursion]');
  out.writeln("  /// sets SQL Server's failure guard for recursive expansion.");
  out.writeln('  ///');
  out.writeln('  /// [cycles] throws by default; use');
  out.writeln('  /// [MssqlCycleHandling.skipVisited] to ignore revisits.');
  out.writeln('  ///');
  out.writeln('  /// Query scopes apply to results, not hierarchy traversal.');
  out.writeln('  $name descendantsOf(');
  out.writeln('    $keyType root, {');
  out.writeln('    int? maxDepth,');
  out.writeln('    bool includeRoot = true,');
  out.writeln('    MssqlCycleHandling cycles = MssqlCycleHandling.error,');
  out.writeln('    int? maxRecursion,');
  out.writeln('  }) {');
  out.writeln('    final walk = hierarchy.descendantsCte(');
  out.writeln('      root,');
  out.writeln('      maxDepth: maxDepth,');
  out.writeln('      cycles: cycles,');
  out.writeln('      maxRecursion: maxRecursion,');
  out.writeln('    );');
  out.writeln('    var keys = MssqlQuery.from(walk.name, ref: walk.ref)');
  out.writeln('        .select(<MssqlExpression>[');
  out.writeln('      walk.column(MssqlHierarchy.keyField),');
  out.writeln('    ]);');
  out.writeln('    if (!includeRoot) {');
  out.writeln('      keys = keys.where(');
  out.writeln('        walk.column(MssqlHierarchy.depthField).gt(0),');
  out.writeln('      );');
  out.writeln('    }');
  out.writeln('    return withTypedCte(walk).where(');
  out.writeln('      (f) => MssqlInSubquery(');
  out.writeln('        f.${key.dartName},');
  out.writeln('        keys,');
  out.writeln('        negated: false,');
  out.writeln('      ),');
  out.writeln('    );');
  out.writeln('  }');
}
