import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';

import '../config.dart';
import '../dart_type.dart';
import '../describe.dart';
import '../generation_banner.dart';
import '../naming.dart';
import '../query_file.dart';

/// Writes `procedures.g.dart`: typed `db.procedures` methods over
/// [MssqlSession.callProcedure].
String emitProcedures(
  List<DescribedQuery> procedures,
  GeneratorConfig config, {
  required String version,
  Set<String> reservedNames = const <String>{},
}) {
  _checkNames(procedures, reservedNames);
  final needsTypedData = procedures.any(
    (query) => _sets(query).any(
      (set) => set.columns.any(
        (column) => _columnType(query, column, config).name == 'Uint8List',
      ),
    ),
  );
  final out = StringBuffer();
  writeGenerationBanner(out, version: version);
  out.writeln('//');
  out.writeln('// Stored procedures via callProcedure, not EXEC strings.');
  out.writeln('// Extra result sets are manual: sp_describe_first_result_set');
  out.writeln('// cannot see them.');
  out.writeln();
  if (needsTypedData) out.writeln("import 'dart:typed_data';");
  out
    ..writeln("import 'package:mssql_native/mssql_native.dart';")
    ..writeln("import 'package:mssql_orm/orm.dart';")
    ..writeln("import 'database.g.dart';")
    ..writeln();

  for (final query in procedures) {
    _emitTvpRows(out, query, config);
    _emitResultRows(out, query, config);
    _emitResultClass(out, query, config);
    out.writeln();
  }

  final className_ = '${config.databaseClass}Procedures';
  out.writeln('/// Typed stored-procedure methods on the generated database.');
  out.writeln('class $className_ {');
  out.writeln('  $className_(this._db);');
  out.writeln('  final ${config.databaseClass} _db;');
  for (final query in procedures) {
    _emitMethod(out, query, config);
  }
  out.writeln('}');
  return out.toString();
}

void _checkNames(List<DescribedQuery> procedures, Set<String> reserved) {
  const builtIn = <String>{
    'reports',
    'procedures',
    'session',
    'clock',
    'owned',
    'changes',
    'capabilities',
    'observer',
    'observerOptions',
    'transaction',
    'close',
    'fork',
    'query',
    'execute',
    'open',
    'borrow',
    'contextFor',
  };
  final seen = <String, String>{};
  for (final query in procedures) {
    final method = fieldName(query.definition.name);
    if (seen.containsKey(method)) {
      throw QueryFileError(
        query.definition.sourcePath,
        'The Dart method "$method" is already used by ${seen[method]}.',
      );
    }
    seen[method] = query.definition.sourcePath;
    if (builtIn.contains(method) || reserved.contains(method)) {
      throw QueryFileError(
        query.definition.sourcePath,
        'The Dart method "$method" collides with AppDatabase.$method.',
      );
    }
  }
}

void _emitTvpRows(
  StringBuffer out,
  DescribedQuery query,
  GeneratorConfig config,
) {
  for (final parameter in query.definition.parameters) {
    if (parameter.tableType == null) continue;
    final columns =
        query.definition.tvpColumns[parameter.name] ?? const <ManualColumn>[];
    final rowClass =
        '${className(query.definition.name)}${className(parameter.name)}Row';
    out.writeln('/// One row of ${parameter.tableType} for ${parameter.name}.');
    out.writeln('class $rowClass {');
    out.write('  const $rowClass({');
    for (final column in columns) {
      final dart = fieldName(column.name);
      out.write(column.nullable ? 'this.$dart, ' : 'required this.$dart, ');
    }
    out.writeln('});');
    for (final column in columns) {
      final type = _columnType(query, column, config);
      out.writeln(
        '  final ${type.declared(column.nullable)} ${fieldName(column.name)};',
      );
    }
    out.writeln('  Map<String, Object?> toColumns() => <String, Object?>{');
    for (final column in columns) {
      out.writeln(
        '    ${dartStringLiteral(column.name)}: ${fieldName(column.name)},',
      );
    }
    out.writeln('  };');
    out.writeln('}');
    out.writeln();
  }
}

void _emitResultRows(
  StringBuffer out,
  DescribedQuery query,
  GeneratorConfig config,
) {
  final sets = _sets(query);
  for (var i = 0; i < sets.length; i++) {
    final set = sets[i];
    if (set.columns.isEmpty) continue;
    final rowClass = _setRowClass(query, set.name);
    out.writeln('/// Result set ${set.name} of ${query.definition.name}.');
    out.writeln('class $rowClass {');
    out.write('  const $rowClass({');
    for (final column in set.columns) {
      final dart = fieldName(column.name);
      final nullable = _nullable(query, column);
      out.write(nullable ? 'this.$dart, ' : 'required this.$dart, ');
    }
    out.writeln('});');
    for (final column in set.columns) {
      final type = _columnType(query, column, config);
      final nullable = _nullable(query, column);
      out.writeln(
        '  final ${type.declared(nullable)} ${fieldName(column.name)};',
      );
    }
    out.writeln(
      '  static const List<String> columnOrder = <String>['
      '${set.columns.map((c) => dartStringLiteral(c.name)).join(', ')}];',
    );
    out.writeln('  factory $rowClass.fromRow(MssqlRow row) {');
    out.writeln('    row.assertOrdinalNames(columnOrder);');
    out.writeln('    return $rowClass(');
    for (var c = 0; c < set.columns.length; c++) {
      final column = set.columns[c];
      final type = _columnType(query, column, config);
      final nullable = _nullable(query, column);
      final access = nullable
          ? 'row.at($c)'
          : 'mssqlRequireNonNull(row.at($c), source: '
                '${dartStringLiteral(query.definition.sourcePath)}, '
                'column: ${dartStringLiteral(column.name)})';
      out.writeln(
        '      ${fieldName(column.name)}: ${type.readable(access, nullable)},',
      );
    }
    out.writeln('    );');
    out.writeln('  }');
    out.writeln('}');
    out.writeln();
  }
}

void _emitResultClass(
  StringBuffer out,
  DescribedQuery query,
  GeneratorConfig config,
) {
  final resultClass = '${className(query.definition.name)}Result';
  final outputs = _outputs(query);
  final sets = _sets(query);
  out.writeln(
    '/// Return status, outputs and result sets of '
    '${query.definition.procedure}.',
  );
  out.writeln('class $resultClass {');
  out.write('  const $resultClass({required this.returnStatus, ');
  for (final p in outputs) {
    out.write('this.${fieldName(p.name)}, ');
  }
  for (final set in sets) {
    if (set.columns.isEmpty) continue;
    out.write('required this.${set.name}, ');
  }
  out.writeln('});');
  out.writeln('  final int returnStatus;');
  for (final p in outputs) {
    final type = _paramType(query, p, config);
    out.writeln('  final ${type.declared(p.nullable)} ${fieldName(p.name)};');
  }
  for (final set in sets) {
    if (set.columns.isEmpty) continue;
    out.writeln('  final List<${_setRowClass(query, set.name)}> ${set.name};');
  }
  out.writeln('}');
}

void _emitMethod(
  StringBuffer out,
  DescribedQuery query,
  GeneratorConfig config,
) {
  final definition = query.definition;
  final method = fieldName(definition.name);
  final resultClass = '${className(definition.name)}Result';
  final args = <String>[
    for (final p in definition.parameters) _argument(query, p, config),
    'MssqlQueryOptions options = MssqlQueryOptions.defaults',
    'Duration? timeout',
    'MssqlCancellationToken? cancellationToken',
  ]..removeWhere((s) => s.isEmpty);
  out.writeln();
  out.writeln('  /// ${definition.sourcePath}');
  out.writeln('  ///');
  out.writeln('  /// ${definition.procedure}. Never retried.');
  if (definition.extraResultSets.isNotEmpty) {
    out.writeln('  ///');
    out.writeln('  /// Extra result sets are declared by hand because');
    out.writeln('  /// sp_describe_first_result_set cannot see them.');
  }
  out.writeln('  Future<$resultClass> $method({${args.join(', ')}}) async {');
  out.writeln('    final parameters = <String, Object?>{');
  for (final p in definition.parameters) {
    final dart = fieldName(p.name);
    if (p.tableType != null) {
      out.writeln(
        "      '${p.name}': MssqlTableRows("
        '$dart.map((row) => row.toColumns())),',
      );
    } else if (p.hasDefault) {
      out.writeln('      if ($dart.isPresent)');
      out.writeln("        '${p.name}': ${_bindRaw(p, '$dart.value')},");
    } else if (p.direction == QueryParameterDirection.output) {
      out.writeln("      '${p.name}': ${_bindRaw(p, 'null')},");
    } else {
      out.writeln("      '${p.name}': ${_bindRaw(p, dart)},");
    }
  }
  out.writeln('    };');
  final outputNames = [
    for (final p in definition.parameters)
      if (p.direction != QueryParameterDirection.input)
        dartStringLiteral(p.name),
  ];
  out.writeln('    final declared = MssqlProcedureMetadata(');
  out.writeln('      procedure: ${dartStringLiteral(definition.procedure!)},');
  out.writeln(
    '      schemaVersion: ${dartStringLiteral(definition.sourceHash)},',
  );
  out.writeln('      parameters: <MssqlProcedureParameter>[');
  for (final p in definition.parameters) {
    out.writeln('        ${_metadataParam(p)},');
  }
  out.writeln('      ],');
  out.writeln('    );');
  out.writeln('    final result = await _db.session.callProcedure(');
  out.writeln('      ${dartStringLiteral(definition.procedure!)},');
  out.writeln('      parameters: parameters,');
  out.writeln('      outputParameters: <String>{${outputNames.join(', ')}},');
  out.writeln("      options: options.merge(queryName: 'procedures.$method'),");
  out.writeln('      timeout: timeout,');
  out.writeln('      cancellationToken: cancellationToken,');
  out.writeln('      declared: declared,');
  out.writeln('      driftPolicy: MssqlMetadataDriftPolicy.verifyDeclared,');
  out.writeln('    );');

  final sets = _sets(query);
  final expected = sets.where((s) => s.columns.isNotEmpty).length;
  final cmp = definition.extraSets == QueryExtraSets.error ? '!=' : '<';
  out.writeln('    if (result.resultSets.length $cmp $expected) {');
  out.writeln('      throw MssqlUnexpectedResultSetException(');
  out.writeln("        procedure: '$method',");
  out.writeln('        expected: $expected,');
  out.writeln('        actual: result.resultSets.length,');
  out.writeln('      );');
  out.writeln('    }');
  for (final p in _outputs(query)) {
    out.writeln("    if (!result.outputParameters.containsKey('${p.name}')) {");
    out.writeln('      throw MssqlMissingOutputException(');
    out.writeln("        procedure: '$method',");
    out.writeln("        parameter: '${p.name}',");
    out.writeln('      );');
    out.writeln('    }');
  }
  out.writeln('    return $resultClass(');
  out.writeln('      returnStatus: result.returnStatus ?? 0,');
  for (final p in _outputs(query)) {
    final type = _paramType(query, p, config);
    final access = p.nullable
        ? "result.outputParameters['${p.name}']"
        : "mssqlRequireNonNull(result.outputParameters['${p.name}'], "
              "source: ${dartStringLiteral(definition.sourcePath)}, "
              "column: '${p.name}')";
    out.writeln(
      '      ${fieldName(p.name)}: ${type.readable(access, p.nullable)},',
    );
  }
  var setIndex = 0;
  for (final set in sets) {
    if (set.columns.isEmpty) continue;
    final rowClass = _setRowClass(query, set.name);
    out.writeln(
      '      ${set.name}: result.resultSets[$setIndex].typedRows'
      '.map($rowClass.fromRow).toList(growable: false),',
    );
    setIndex++;
  }
  out.writeln('    );');
  out.writeln('  }');
}

String _argument(
  DescribedQuery query,
  DeclaredParameter p,
  GeneratorConfig config,
) {
  final dart = fieldName(p.name);
  if (p.tableType != null) {
    final rowClass =
        '${className(query.definition.name)}${className(p.name)}Row';
    return 'required List<$rowClass> $dart';
  }
  if (p.direction == QueryParameterDirection.output && !p.hasDefault) {
    return '';
  }
  if (p.hasDefault) {
    final inner = _paramType(query, p, config).declared(p.nullable);
    return 'Field<$inner> $dart = const AbsentField()';
  }
  final type = _paramType(query, p, config).declared(p.nullable);
  return p.nullable ? '$type $dart' : 'required $type $dart';
}

String _bindRaw(DeclaredParameter p, String expr) {
  final type = mssqlTypeForSqlTypeName(p.sqlTypeName) ?? MssqlType.varchar;
  final size = p.maxLength;
  final precision = p.precision == 0 ? 18 : p.precision;
  final scale = p.scale;
  return switch (type) {
    MssqlType.bit => 'MssqlValue.bit($expr)',
    MssqlType.tinyInt => 'MssqlValue.tinyInt($expr)',
    MssqlType.smallInt => 'MssqlValue.smallInt($expr)',
    MssqlType.int32 => 'MssqlValue.int32($expr)',
    MssqlType.int64 => 'MssqlValue.int64($expr)',
    MssqlType.real => 'MssqlValue.real($expr)',
    MssqlType.float64 => 'MssqlValue.float64($expr)',
    MssqlType.decimal =>
      'MssqlValue.decimal($expr, precision: $precision, scale: $scale)',
    MssqlType.numeric =>
      'MssqlValue.numeric($expr, precision: $precision, scale: $scale)',
    MssqlType.money => 'MssqlValue.money($expr)',
    MssqlType.smallMoney => 'MssqlValue.smallMoney($expr)',
    MssqlType.char => 'MssqlValue.char($expr, size: ${size == 0 ? 1 : size})',
    MssqlType.varchar => 'MssqlValue.varchar($expr, size: $size)',
    MssqlType.nchar => 'MssqlValue.nchar($expr, size: ${size == 0 ? 1 : size})',
    MssqlType.nvarchar => 'MssqlValue.nvarchar($expr, size: $size)',
    MssqlType.text => 'MssqlValue.text($expr)',
    MssqlType.ntext => 'MssqlValue.ntext($expr)',
    MssqlType.binary =>
      'MssqlValue.binary($expr, size: ${size == 0 ? 1 : size})',
    MssqlType.varbinary => 'MssqlValue.varbinary($expr, size: $size)',
    MssqlType.image => 'MssqlValue.image($expr)',
    MssqlType.date => 'MssqlValue.date($expr)',
    MssqlType.time =>
      'MssqlValue.time($expr, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.smallDateTime => 'MssqlValue.smallDateTime($expr)',
    MssqlType.dateTime => 'MssqlValue.dateTime($expr)',
    MssqlType.dateTime2 =>
      'MssqlValue.dateTime2($expr, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.dateTimeOffset =>
      'MssqlValue.dateTimeOffset($expr, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.uniqueIdentifier => 'MssqlValue.uniqueIdentifier($expr)',
    MssqlType.xml => 'MssqlValue.xml($expr)',
  };
}

String _metadataParam(DeclaredParameter p) {
  final table = p.tableType;
  final type = table == null
      ? (mssqlTypeForSqlTypeName(p.sqlTypeName) ?? MssqlType.varchar)
      : MssqlType.nvarchar;
  final typeLit = 'MssqlType.${type.name}';
  final isOutput = p.direction != QueryParameterDirection.input;
  final schema = table == null
      ? ''
      : table.contains('.')
      ? ", tableTypeSchema: '${table.split('.').first}', "
            "tableTypeName: '${table.split('.').last}'"
      : ", tableTypeName: '$table'";
  return 'MssqlProcedureParameter(name: \'${p.name}\', type: $typeLit, '
      'size: ${p.maxLength}, precision: ${p.precision}, scale: ${p.scale}, '
      'isOutput: $isOutput, isReadOnly: ${table != null}$schema)';
}

class _Set {
  const _Set(this.name, this.columns);
  final String name;
  final List<ManualColumn> columns;
}

List<DeclaredParameter> _outputs(DescribedQuery query) => [
  for (final p in query.definition.parameters)
    if (p.direction != QueryParameterDirection.input) p,
];

List<_Set> _sets(DescribedQuery query) {
  final first = <ManualColumn>[
    if (query.definition.manualColumns != null)
      ...query.definition.manualColumns!
    else
      for (final c in query.columns)
        ManualColumn(
          name: c.name,
          sqlTypeName: c.sqlTypeName,
          nullable: c.nullable,
          maxLength: c.maxLength,
          precision: c.precision,
          scale: c.scale,
        ),
  ];
  return <_Set>[
    if (first.isNotEmpty)
      _Set(query.definition.firstResultSetName ?? 'set0', first),
    for (final extra in query.definition.extraResultSets)
      _Set(extra.name, extra.columns),
  ];
}

String _setRowClass(DescribedQuery query, String name) =>
    '${className(query.definition.name)}${className(name)}Row';

bool _nullable(DescribedQuery query, ManualColumn column) =>
    column.nullable &&
    !query.definition.notNullColumns.any(
      (n) => n.toLowerCase() == column.name.toLowerCase(),
    );

DartFieldType _columnType(
  DescribedQuery query,
  ManualColumn column,
  GeneratorConfig config,
) => dartTypeFor(
  _host(query),
  MssqlColumnSchema(
    ordinal: 1,
    name: column.name,
    sqlTypeName: column.sqlTypeName,
    type: mssqlTypeForSqlTypeName(column.sqlTypeName) ?? MssqlType.varchar,
    nullable: column.nullable,
    isIdentity: false,
    isComputed: false,
    isRowVersion: false,
    hasDefault: false,
    maxLength: column.maxLength,
    precision: column.precision,
    scale: column.scale,
  ),
  decimalMode: config.decimalMode,
);

DartFieldType _paramType(
  DescribedQuery query,
  DeclaredParameter parameter,
  GeneratorConfig config,
) => dartTypeFor(
  _host(query),
  MssqlColumnSchema(
    ordinal: 1,
    name: parameter.name,
    sqlTypeName: parameter.sqlTypeName,
    type: mssqlTypeForSqlTypeName(parameter.sqlTypeName) ?? MssqlType.varchar,
    nullable: parameter.nullable,
    isIdentity: false,
    isComputed: false,
    isRowVersion: false,
    hasDefault: false,
    maxLength: parameter.maxLength,
    precision: parameter.precision,
    scale: parameter.scale,
  ),
  decimalMode: config.decimalMode,
);

MssqlTableSchema _host(DescribedQuery query) => MssqlTableSchema(
  schema: 'procedure',
  name: query.definition.name,
  isView: true,
  columns: const <MssqlColumnSchema>[],
  primaryKey: null,
  foreignKeys: const <MssqlForeignKeySchema>[],
);
