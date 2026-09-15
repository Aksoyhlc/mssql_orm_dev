part of '../emitter.dart';

void _emitColumnsClass(StringBuffer out, TablePlan plan) {
  out.writeln('/// Typed column references for ${plan.table.qualifiedName}.');
  out.writeln('abstract final class ${plan.columnsClass} {');
  out.writeln(
    '  static const String table = '
    '${dartStringLiteral(plan.table.qualifiedName)};',
  );
  out.writeln();
  out.writeln('  /// Which table these columns belong to.');
  out.writeln('  ///');
  out.writeln('  /// Shared so columns can be rebound to aliases or schemas.');
  out.writeln(
    '  static const MssqlSourceRef source = MssqlSourceRef('
    'schema: ${dartStringLiteral(plan.table.schema)}, '
    'table: ${dartStringLiteral(plan.table.name)});',
  );
  for (final field in plan.fields) {
    out.writeln();
    _emitColumnDoc(out, plan, field);
    out.writeln(
      '  static final ${_columnClassFor(field)} ${field.dartName} = '
      '${_builderName(field)}(source);',
    );
  }
  out.writeln();
  out.writeln('  /// The same columns bound to another source.');
  for (final field in plan.fields) {
    out.writeln();
    out.writeln(
      '  static ${_columnClassFor(field)} ${_builderName(field)}('
      'MssqlSourceRef source) =>',
    );
    out.writeln('      ${_columnClassFor(field)}.of(');
    out.writeln('        source: source,');
    out.writeln('        name: ${dartStringLiteral(field.column.name)},');
    out.writeln(
      '        quotedName: '
      '${dartStringLiteral(MssqlSql.quoteIdentifier(field.column.name))},',
    );
    out.writeln('        columnType: ${_columnTypeFor(field)},');
    out.writeln('      );');
  }
  out.writeln('}');
}

/// Typed callback fields for `where((o) => o.status.eq(…))`.
void _emitFieldsClass(StringBuffer out, TablePlan plan) {
  out.writeln('/// Typed SQL columns of ${plan.table.qualifiedName}.');
  out.writeln('///');
  out.writeln(
    '/// Used by query callbacks; these are expressions, not row values.',
  );
  out.writeln('class ${plan.fieldsClass} {');
  out.writeln(
    '  /// Uses the generated table or an explicitly rebound source.',
  );
  out.writeln('  const ${plan.fieldsClass}([this._source]);');
  out.writeln();
  out.writeln('  final MssqlSourceRef? _source;');
  out.writeln();
  out.writeln('  /// Which source these columns resolve against.');
  out.writeln(
    '  MssqlSourceRef get source => _source ?? '
    '${plan.columnsClass}.source;',
  );
  for (final field in plan.fields) {
    out.writeln();
    _emitColumnDoc(out, plan, field);
    out.writeln('  ///');
    out.writeln(
      '  /// `${plan.whereShortcut(field)}` ANDs an equality on this '
      'column.',
    );
    out.writeln('  ${_columnClassFor(field)} get ${field.dartName} {');
    out.writeln('    final ref = _source;');
    out.writeln(
      '    return ref == null'
      ' ? ${plan.columnsClass}.${field.dartName}'
      ' : ${plan.columnsClass}.${_builderName(field)}(ref);',
    );
    out.writeln('  }');
  }
  for (final relation in plan.relations) {
    final targetRow = _generatedRowClass(plan.config, relation.target);
    out.writeln();
    out.writeln('  /// Include handle for `${relation.name}`.');
    out.writeln('  ///');
    out.writeln('  /// Loaded with `include((o) => [o.${relation.name}])`.');
    out.writeln(
      '  MssqlRelation<${plan.rowClass}, $targetRow> get ${relation.name} => '
      '${plan.columnsClass}Rel.${relation.name};',
    );
  }
  out.writeln('}');
}

/// Emits the SQL type and relevant schema attributes for a column.
void _emitColumnDoc(StringBuffer out, TablePlan plan, FieldPlan field) {
  final column = field.column;
  final notes = <String>[
    if (column.nullable) 'nullable' else 'NOT NULL',
    if (column.isIdentity) 'IDENTITY',
    if (column.isComputed) 'computed',
    if (column.isRowVersion) 'rowversion',
    if (column.hasDefault) 'has a default',
    if (!field.writable) 'read-only',
  ];
  out.writeln(
    '  /// `${plan.table.qualifiedName}.${column.name}` '
    ': ${column.sqlTypeName}, ${notes.join(', ')}.',
  );
}

/// Selects the typed column class that exposes valid predicates for [field].
String _columnClassFor(FieldPlan field) {
  if (field.column.type == MssqlType.uniqueIdentifier) return 'MssqlGuidColumn';
  return switch (field.type.name) {
    'int' => 'MssqlIntColumn',
    'double' => 'MssqlDoubleColumn',
    'MssqlDecimal' => 'MssqlDecimalColumn',
    'String' => 'MssqlStringColumn',
    'bool' => 'MssqlBoolColumn',
    'DateTime' => 'MssqlDateTimeColumn',
    'Duration' => 'MssqlTimeColumn',
    'MssqlDateTimeValue' => 'MssqlDateTimeValueColumn',
    'Uint8List' => 'MssqlBinaryColumn',
    // A converter's Dart type is the application's, so the column keeps the
    // general shape: comparable, and nothing type-specific claimed for it.
    _ => 'MssqlTypedColumn<${field.type.name}>',
  };
}

/// Emits the column type expected by the runtime codec.
///
/// Wide-character lengths are converted from catalog bytes to UTF-16 units.
String _columnTypeFor(FieldPlan field) {
  final column = field.column;
  final bytes = column.maxLength < 0 ? 0 : column.maxLength;
  final wide =
      column.type == MssqlType.nchar || column.type == MssqlType.nvarchar;
  return 'MssqlColumnType('
      'type: MssqlType.${column.type.name}, '
      'size: ${wide ? bytes ~/ 2 : bytes}, '
      'precision: ${column.precision}, '
      'scale: ${column.scale}, '
      'nullable: ${column.nullable}, '
      'columnName: ${dartStringLiteral(column.name)})';
}

/// Names the builder that preserves a column's concrete type when rebound.
String _builderName(FieldPlan field) => 'column\$${field.dartName}';
