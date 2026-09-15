import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';

import 'config.dart';
import 'dart_type.dart';
import 'describe.dart';
import 'generation_banner.dart';
import 'naming.dart';
import 'query_file.dart';

/// Writes the file holding a typed row class and `db.reports` methods.
String emitQueries(
  List<DescribedQuery> queries,
  GeneratorConfig config, {
  required String version,
  Set<String> reservedNames = const <String>{},
}) {
  _checkMethodNames(queries, reservedNames);
  // `query_runner` partitions by `procedure`, so a procedure-backed query
  // belongs to `emitProcedures` and never reaches here. This checks rather than
  // trusts it: the emitter reads only `sql`, and a procedure query carries
  // none, so emitting one would send an empty statement.
  for (final query in queries) {
    final procedure = query.definition.procedure;
    if (procedure != null) {
      throw StateError(
        'emitQueries was given "${query.definition.name}", which names the '
        'stored procedure $procedure rather than a statement. A procedure is '
        'generated onto db.procedures by emitProcedures, which calls it '
        'through MssqlSession.callProcedure so its output parameters and '
        'extra result sets are typed — an EXEC string cannot carry those.',
      );
    }
  }

  final out = StringBuffer();
  writeGenerationBanner(out, version: version);
  out.writeln('//');
  out.writeln('// Typed from SQL Server\'s own description of each query, by');
  out.writeln('// sp_describe_first_result_set, or from -- describe: manual.');
  out.writeln('// Manual shapes are not a server-verified static analysis.');
  out.writeln();

  final needsTypedData = queries.any(
    (q) => q.columns.any(
      (c) =>
          dartTypeFor(
            _hostTable(q),
            c.asColumn(),
            decimalMode: config.decimalMode,
          ).name ==
          'Uint8List',
    ),
  );
  if (needsTypedData) out.writeln("import 'dart:typed_data';");
  out
    ..writeln("import 'package:meta/meta.dart';")
    ..writeln("import 'package:mssql_native/mssql_native.dart';")
    ..writeln("import 'package:mssql_orm/orm.dart';")
    ..writeln("import 'database.g.dart';")
    ..writeln();

  final rowClasses = <String, String>{};
  for (final query in queries) {
    if (query.columns.isEmpty) continue;
    final rowClass = '${className(query.definition.name)}Row';
    rowClasses[query.definition.name] = rowClass;
    _emitRow(out, query, rowClass, config);
    out.writeln();
  }

  final reportsClass = '${config.databaseClass}Reports';
  out.writeln('/// Typed methods for every `.sql` file, on the generated');
  out.writeln('/// database. Call `db.reports.methodName(...)`.');
  out.writeln('///');
  out.writeln(
    '/// Retry is never unless the file declared `-- read_only: true`.',
  );
  out.writeln('/// Returning rows does not make a statement safe to repeat.');
  out.writeln('class $reportsClass {');
  out.writeln('  $reportsClass(this._db);');
  out.writeln();
  out.writeln('  final ${config.databaseClass} _db;');
  out.writeln();
  for (final query in queries) {
    _emitMethod(out, query, rowClasses[query.definition.name], config);
  }
  out.writeln('}');
  return out.toString();
}

void _checkMethodNames(
  List<DescribedQuery> queries,
  Set<String> reservedNames,
) {
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
  final reserved = <String>{...builtIn, ...reservedNames};
  final seen = <String, String>{};
  for (final query in queries) {
    final method = fieldName(query.definition.name);
    final previous = seen[method];
    if (previous != null) {
      throw QueryFileError(
        query.definition.sourcePath,
        'The Dart method "$method" is already used by $previous after '
        'name conversion. Two queries cannot share one method name.',
      );
    }
    seen[method] = query.definition.sourcePath;
    if (reserved.contains(method)) {
      throw QueryFileError(
        query.definition.sourcePath,
        'The Dart method "$method" collides with AppDatabase.$method. '
        'Rename the query with "-- name:".',
      );
    }
  }
}

/// The type mapping takes a table for context it does not use for a query
/// column; this stands in for it.
MssqlTableSchema _hostTable(DescribedQuery query) => MssqlTableSchema(
  schema: 'query',
  name: query.definition.name,
  isView: true,
  columns: const <MssqlColumnSchema>[],
  primaryKey: null,
  foreignKeys: const <MssqlForeignKeySchema>[],
);

void _emitRow(
  StringBuffer out,
  DescribedQuery query,
  String rowClass,
  GeneratorConfig config,
) {
  final fields = _fieldsOf(query, config);
  out.writeln('/// One row of ${query.definition.name}.');
  out.writeln('///');
  out.writeln('/// Source: ${query.definition.sourcePath}');
  out.writeln('@immutable');
  out.writeln('class $rowClass {');
  out.write('  const $rowClass({');
  for (final f in fields) {
    out.write(f.nullable ? 'this.${f.name}, ' : 'required this.${f.name}, ');
  }
  out.writeln('});');
  out.writeln();
  for (final f in fields) {
    if (f.note != null) out.writeln('  /// ${f.note}');
    out.writeln('  final ${f.declared} ${f.name};');
  }
  out.writeln();
  out.writeln(
    '  static const List<String> columnOrder = <String>[${fields.map((f) => dartStringLiteral(f.sqlName)).join(', ')}];',
  );
  out.writeln('  factory $rowClass.fromRow(MssqlRow row) {');
  out.writeln('    row.assertOrdinalNames(columnOrder);');
  out.writeln('    return $rowClass(');
  for (final f in fields) {
    out.writeln('      ${f.name}: ${f.read},');
  }
  out.writeln('    );');
  out.writeln('  }');
  out.writeln('}');
}

void _emitMethod(
  StringBuffer out,
  DescribedQuery query,
  String? rowClass,
  GeneratorConfig config,
) {
  final definition = query.definition;
  final method = fieldName(definition.name);
  final parameters = query.parameters;
  final fields = query.columns.isEmpty
      ? const <_Field>[]
      : _fieldsOf(query, config);

  final named = <String>[
    for (final p in parameters)
      '${p.nullable ? '' : 'required '}'
          '${_parameterDartType(query, p, config)} ${fieldName(p.name)}',
    'MssqlQueryOptions options = MssqlQueryOptions.defaults',
    'Duration? timeout',
    'MssqlCancellationToken? cancellationToken',
  ];
  final signature = '{${named.join(', ')}}';

  final bind = parameters.isEmpty
      ? 'const <String, Object?>{}'
      : '<String, Object?>{${parameters.map((p) => "'${p.name}': ${_bindParameter(p)}").join(', ')}}';

  final sql = _dartString(definition.sql);
  final retry = definition.readOnly
      ? 'MssqlRetryPolicy.idempotentRead'
      : 'MssqlRetryPolicy.never';
  final queryName = "'reports.$method'";

  final returns = switch (definition.shape) {
    QueryShape.affected => 'Future<int>',
    QueryShape.single => 'Future<$rowClass>',
    QueryShape.singleOrNull => 'Future<$rowClass?>',
    QueryShape.list => 'Future<List<$rowClass>>',
    QueryShape.scalar => 'Future<${fields.single.declared}>',
  };

  out.writeln();
  out.writeln('  /// ${definition.sourcePath}');
  if (definition.isManual) {
    out.writeln('  ///');
    out.writeln('  /// Shape declared by `-- describe: manual`. SQL Server');
    out.writeln('  /// has not verified this query.');
  }
  if (definition.readOnly) {
    out.writeln('  ///');
    out.writeln('  /// `-- read_only: true`: lost connections may retry.');
  }
  out.writeln('  $returns $method($signature) async {');
  out.writeln('    final parameters = $bind;');
  if (definition.shape == QueryShape.affected) {
    out.writeln(
      '    return _db.session.execute($sql, parameters: parameters, '
      'options: options, timeout: timeout, '
      'cancellationToken: cancellationToken);',
    );
  } else {
    out.writeln(
      '    final run = options.merge(retry: $retry, '
      'queryName: $queryName);',
    );
    final limit = definition.shape == QueryShape.list ? '' : ', maximumRows: 2';
    out.writeln(
      '    final rows = await _db.session.queryTypedRows($sql, '
      'parameters: parameters, options: run, timeout: timeout, '
      'cancellationToken: cancellationToken$limit);',
    );
    switch (definition.shape) {
      case QueryShape.list:
        out.writeln(
          '    return rows.map($rowClass.fromRow).toList(growable: false);',
        );
      case QueryShape.single:
        out.writeln('    if (rows.isEmpty) {');
        out.writeln("      throw MssqlRowNotFoundException('$method', null);");
        out.writeln('    }');
        out.writeln('    if (rows.length > 1) {');
        out.writeln(
          "      throw MssqlCardinalityException('$method', 'single', "
          'rows.length);',
        );
        out.writeln('    }');
        out.writeln('    return $rowClass.fromRow(rows.first);');
      case QueryShape.singleOrNull:
        out.writeln('    if (rows.length > 1) {');
        out.writeln(
          "      throw MssqlCardinalityException('$method', 'singleOrNull', "
          'rows.length);',
        );
        out.writeln('    }');
        out.writeln(
          '    return rows.isEmpty ? null : $rowClass.fromRow(rows.first);',
        );
      case QueryShape.scalar:
        out.writeln('    if (rows.isEmpty) {');
        out.writeln("      throw MssqlRowNotFoundException('$method', null);");
        out.writeln('    }');
        out.writeln('    if (rows.length > 1) {');
        out.writeln(
          "      throw MssqlCardinalityException('$method', 'scalar', "
          'rows.length);',
        );
        out.writeln('    }');
        out.writeln(
          '    return $rowClass.fromRow(rows.first).${fields.single.name};',
        );
      case QueryShape.affected:
        break;
    }
  }
  out.writeln('  }');
}

String _parameterDartType(
  DescribedQuery query,
  DescribedParameter parameter,
  GeneratorConfig config,
) {
  final type = dartTypeFor(
    _hostTable(query),
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
  return type.declared(parameter.nullable);
}

String _bindParameter(DescribedParameter parameter) {
  final dart = fieldName(parameter.name);
  final type =
      mssqlTypeForSqlTypeName(parameter.sqlTypeName) ?? MssqlType.varchar;
  final size = parameter.maxLength;
  final precision = parameter.precision == 0 ? 18 : parameter.precision;
  final scale = parameter.scale;
  return switch (type) {
    MssqlType.bit => 'MssqlValue.bit($dart)',
    MssqlType.tinyInt => 'MssqlValue.tinyInt($dart)',
    MssqlType.smallInt => 'MssqlValue.smallInt($dart)',
    MssqlType.int32 => 'MssqlValue.int32($dart)',
    MssqlType.int64 => 'MssqlValue.int64($dart)',
    MssqlType.real => 'MssqlValue.real($dart)',
    MssqlType.float64 => 'MssqlValue.float64($dart)',
    MssqlType.decimal =>
      'MssqlValue.decimal($dart, precision: $precision, scale: $scale)',
    MssqlType.numeric =>
      'MssqlValue.numeric($dart, precision: $precision, scale: $scale)',
    MssqlType.money => 'MssqlValue.money($dart)',
    MssqlType.smallMoney => 'MssqlValue.smallMoney($dart)',
    MssqlType.char => 'MssqlValue.char($dart, size: ${size == 0 ? 1 : size})',
    MssqlType.varchar => 'MssqlValue.varchar($dart, size: $size)',
    MssqlType.nchar => 'MssqlValue.nchar($dart, size: ${size == 0 ? 1 : size})',
    MssqlType.nvarchar => 'MssqlValue.nvarchar($dart, size: $size)',
    MssqlType.text => 'MssqlValue.text($dart)',
    MssqlType.ntext => 'MssqlValue.ntext($dart)',
    MssqlType.binary =>
      'MssqlValue.binary($dart, size: ${size == 0 ? 1 : size})',
    MssqlType.varbinary => 'MssqlValue.varbinary($dart, size: $size)',
    MssqlType.image => 'MssqlValue.image($dart)',
    MssqlType.date => 'MssqlValue.date($dart)',
    MssqlType.time =>
      'MssqlValue.time($dart, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.smallDateTime => 'MssqlValue.smallDateTime($dart)',
    MssqlType.dateTime => 'MssqlValue.dateTime($dart)',
    MssqlType.dateTime2 =>
      'MssqlValue.dateTime2($dart, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.dateTimeOffset =>
      'MssqlValue.dateTimeOffset($dart, scale: ${scale == 0 ? 7 : scale})',
    MssqlType.uniqueIdentifier => 'MssqlValue.uniqueIdentifier($dart)',
    MssqlType.xml => 'MssqlValue.xml($dart)',
  };
}

class _Field {
  const _Field(
    this.name,
    this.sqlName,
    this.declared,
    this.read,
    this.nullable,
    this.note,
  );
  final String name;
  final String sqlName;
  final String declared;
  final String read;
  final bool nullable;
  final String? note;
}

List<_Field> _fieldsOf(DescribedQuery query, GeneratorConfig config) {
  final host = _hostTable(query);
  final out = <_Field>[];
  final names = <String, String>{};
  for (final column in query.columns) {
    if (column.name.isEmpty) {
      throw QueryFileError(
        query.definition.sourcePath,
        'Column ${column.ordinal} has no name. Give the expression an alias.',
      );
    }
    // The server is conservative about nullability: it is right for outer
    // joins and aggregates, and sometimes over-cautious elsewhere. Following
    // it costs a `?`; overriding it by default would cost a crash.
    final nullable =
        column.nullable &&
        !query.definition.notNullColumns.any(
          (n) => n.toLowerCase() == column.name.toLowerCase(),
        );
    final schema = MssqlColumnSchema(
      ordinal: column.ordinal,
      name: column.name,
      sqlTypeName: column.sqlTypeName,
      type: mssqlTypeForSqlTypeName(column.sqlTypeName) ?? MssqlType.varchar,
      nullable: nullable,
      isIdentity: false,
      isComputed: false,
      isRowVersion: false,
      hasDefault: false,
      maxLength: column.maxLength,
      precision: column.precision,
      scale: column.scale,
    );
    final type = dartTypeFor(host, schema, decimalMode: config.decimalMode);
    final dartName = fieldName(column.name);
    names[column.name] = dartName;
    final index = out.length;
    final access = nullable
        ? 'row.at($index)'
        : "mssqlRequireNonNull(row.at($index), source: '${query.definition.sourcePath}', column: '${column.name}')";
    final decoded = type.readable(access, nullable);
    final read = nullable ? decoded : decoded.replaceFirst('$access!', access);
    final note = <String>[
      if (type.note != null) type.note!,
      if (query.definition.notNullColumns.any(
        (n) => n.toLowerCase() == column.name.toLowerCase(),
      ))
        'Non-null asserted by -- notnull in ${query.definition.sourcePath}. '
            'An unexpected SQL NULL throws naming that file and column.',
    ];
    out.add(
      _Field(
        dartName,
        column.name,
        type.declared(nullable),
        read,
        nullable,
        note.isEmpty ? null : note.join(' '),
      ),
    );
  }
  checkDistinct(query.definition.sourcePath, names);
  return out;
}

/// A Dart string literal for arbitrary SQL, kept on one logical line.
String _dartString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\r', '')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
