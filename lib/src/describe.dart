import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';

import 'query_file.dart';
import 'sql_type_spec.dart';

/// One column of a described result set.
class DescribedColumn {
  const DescribedColumn({
    required this.ordinal,
    required this.name,
    required this.sqlTypeName,
    required this.nullable,
    required this.maxLength,
    required this.precision,
    required this.scale,
  });

  final int ordinal;
  final String name;
  final String sqlTypeName;
  final bool nullable;
  final int maxLength;
  final int precision;
  final int scale;

  /// The same shape the schema reader produces, so one type mapping serves
  /// both generated tables and generated queries.
  MssqlColumnSchema asColumn() => MssqlColumnSchema(
    ordinal: ordinal,
    name: name,
    sqlTypeName: sqlTypeName,
    type: mssqlTypeForSqlTypeName(sqlTypeName) ?? MssqlType.varchar,
    nullable: nullable,
    isIdentity: false,
    isComputed: false,
    isRowVersion: false,
    hasDefault: false,
    maxLength: maxLength,
    precision: precision,
    scale: scale,
  );
}

/// A parameter's type, as the server inferred or the file declared it.
class DescribedParameter {
  const DescribedParameter({
    required this.name,
    required this.sqlTypeName,
    required this.nullable,
    this.declaration,
    this.maxLength = 0,
    this.precision = 0,
    this.scale = 0,
  });

  final String name;
  final String sqlTypeName;
  final bool nullable;

  /// Full declaration such as `nvarchar(50)` or `decimal(18,4)`.
  final String? declaration;
  final int maxLength;
  final int precision;
  final int scale;
}

/// A description plus whatever the server could not confirm about it.
class VerifiedQuery {
  const VerifiedQuery(this.query, {this.drift, this.unverified});

  final DescribedQuery query;

  /// The server disagrees with the declaration.
  final String? drift;

  /// The server could not be asked, so nothing was checked.
  final String? unverified;
}

class DescribedQuery {
  const DescribedQuery({
    required this.definition,
    required this.columns,
    required this.parameters,
  });

  final QueryDefinition definition;
  final List<DescribedColumn> columns;
  final List<DescribedParameter> parameters;
}

/// Raised when SQL Server will not describe a query.
class UndescribableQuery implements Exception {
  const UndescribableQuery(
    this.path,
    this.reason,
    this.serverMessage, {
    this.line,
  });

  final String path;
  final int? line;
  final String reason;
  final String serverMessage;

  @override
  String toString() =>
      'UndescribableQuery: $path${line == null ? '' : ':$line'} — $reason\n'
      '  SQL Server said: $serverMessage\n'
      '  Either make the query describable, or add "-- describe: manual" and '
      'declare its columns with "-- column:" directives.';
}

/// Asks SQL Server what a query returns, without running it.
///
/// Uses `sp_describe_first_result_set` for columns and
/// `sp_describe_undeclared_parameters` for parameter types.
class QueryDescriber {
  QueryDescriber(this.connection);

  final MssqlConnection connection;

  static const Duration _timeout = Duration(seconds: 30);

  Future<DescribedQuery> describe(QueryDefinition definition) async {
    if (definition.isManual) {
      return describeManual(definition);
    }

    // Parameters first: sp_describe_first_result_set compiles the statement,
    // and a parameter that decides a result column has to be declared in the
    // call for that to succeed.
    final parameters = await _describeParameters(definition);
    final columns = definition.shape == QueryShape.affected
        ? const <DescribedColumn>[]
        : await _describeColumns(definition, parameters);
    if (definition.shape == QueryShape.scalar && columns.length != 1) {
      throw QueryFileError(
        definition.sourcePath,
        'returns: scalar needs exactly one result column; SQL Server '
        'described ${columns.length}.',
        line: definition.sqlLine,
      );
    }
    return DescribedQuery(
      definition: definition,
      columns: columns,
      parameters: parameters,
    );
  }

  Future<List<DescribedColumn>> _describeColumns(
    QueryDefinition definition,
    List<DescribedParameter> parameters,
  ) async {
    final List<Map<String, Object?>> rows;
    final declarations = _paramsDeclaration(definition, parameters);
    try {
      // The statement and its parameter declarations are passed as parameters
      // rather than concatenated into the call. The procedure compiles the
      // statement and never runs it.
      rows = await connection.queryRows(
        'EXEC sp_describe_first_result_set @tsql = @tsql, '
        '@params = @params, @browse_information_mode = 0;',
        parameters: <String, Object?>{
          'tsql': MssqlValue.nvarchar(_describeText(definition)),
          'params': declarations == null
              ? MssqlValue.nvarchar(null)
              : MssqlValue.nvarchar(declarations),
        },
        timeout: _timeout,
      );
    } on MssqlException catch (error) {
      throw UndescribableQuery(
        definition.sourcePath,
        _reasonFor(definition, error),
        error.message,
        line: definition.sqlLine,
      );
    }

    if (rows.isEmpty) {
      throw UndescribableQuery(
        definition.sourcePath,
        'SQL Server described no columns. A statement that returns nothing '
            'should say "-- returns: affected". A scalar needs one column.',
        'no rows from sp_describe_first_result_set',
        line: definition.sqlLine,
      );
    }

    return [
      for (final r in rows)
        () {
          final systemType = r['system_type_name']! as String;
          final spec = _specFromServer(systemType);
          return DescribedColumn(
            ordinal: (r['column_ordinal']! as num).toInt(),
            name: (r['name'] as String?) ?? '',
            sqlTypeName: spec.baseName,
            nullable: _bool(r['is_nullable']),
            maxLength: spec.isMax
                ? 0
                : (spec.maxLength != 0
                      ? spec.maxLength
                      : ((r['max_length'] as num?)?.toInt() ?? 0)),
            precision: (r['precision'] as num?)?.toInt() ?? spec.precision,
            scale: (r['scale'] as num?)?.toInt() ?? spec.scale,
          );
        }(),
    ];
  }

  Future<List<DescribedParameter>> _describeParameters(
    QueryDefinition definition,
  ) async {
    final declared = <String, DeclaredParameter>{
      for (final p in definition.parameters) p.name.toLowerCase(): p,
    };
    // A declared type is the last word: inference cannot see a parameter used
    // only inside an expression, and it sometimes suggests a wider type than
    // the column it is compared against.
    if (definition.procedure != null) {
      return <DescribedParameter>[
        for (final p in definition.parameters) _declaredParameter(p),
      ];
    }

    List<Map<String, Object?>> rows;
    try {
      rows = await connection.queryRows(
        'EXEC sp_describe_undeclared_parameters @tsql = @tsql;',
        parameters: <String, Object?>{
          'tsql': MssqlValue.nvarchar(definition.sql),
        },
        timeout: _timeout,
      );
    } on MssqlException catch (error) {
      // Whether sp_describe_undeclared_parameters returns an empty set or
      // raises for a statement with no parameters varies across versions and
      // editions, so the question is asked of the statement instead: a
      // statement that mentions no parameter has none. A statement that does
      // mention one and still failed indicates a permission, syntax or
      // connection error.
      if (declared.isEmpty && !_mentionsParameter(definition.sql)) {
        return const <DescribedParameter>[];
      }
      // Every parameter the statement mentions is declared in the file, so
      // inference has nothing to add and its refusal can be ignored.
      // sp_describe_undeclared_parameters will not analyse a batch that uses
      // one parameter twice, which is an ordinary query.
      if (_mentionedParameters(
        definition.sql,
      ).every((name) => declared.containsKey(name))) {
        return <DescribedParameter>[
          for (final p in definition.parameters) _declaredParameter(p),
        ];
      }
      throw UndescribableQuery(
        definition.sourcePath,
        _parameterReason(error),
        error.message,
        line: definition.sqlLine,
      );
    }

    final inferred = <String, DescribedParameter>{};
    for (final row in rows) {
      final raw = row['name']! as String;
      final name = raw.startsWith('@') ? raw.substring(1) : raw;
      final suggested = row['suggested_system_type_name']! as String;
      final spec = _specFromServer(suggested);
      inferred[name.toLowerCase()] = DescribedParameter(
        name: name,
        sqlTypeName: spec.baseName,
        nullable: _bool(row['suggested_is_nullable']),
        declaration: spec.declaration,
        maxLength: spec.isMax
            ? 0
            : ((row['suggested_max_length'] as num?)?.toInt() ??
                  spec.maxLength),
        precision:
            (row['suggested_precision'] as num?)?.toInt() ?? spec.precision,
        scale: (row['suggested_scale'] as num?)?.toInt() ?? spec.scale,
      );
    }

    final names = <String>{...inferred.keys, ...declared.keys};
    final out = <DescribedParameter>[];
    for (final key in names) {
      final override = declared[key];
      if (override != null) {
        out.add(_declaredParameter(override));
      } else {
        out.add(inferred[key]!);
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Verifies a manual declaration against the live server.
  Future<VerifiedQuery> verify(QueryDefinition definition) async {
    if (!definition.isManual) {
      return VerifiedQuery(await describe(definition));
    }
    final declared = describeManual(definition);
    final List<DescribedColumn> live;
    try {
      live = await _describeColumns(definition, declared.parameters);
    } on UndescribableQuery catch (error) {
      return VerifiedQuery(
        declared,
        unverified:
            'SQL Server could not describe this manual query, so its declared '
            'shape was not checked against the schema: ${error.reason}',
      );
    }
    final mismatch = _manualMismatch(declared.columns, live);
    return VerifiedQuery(declared, drift: mismatch);
  }

  /// What the manual declaration gets wrong about the live shape, or null.
  String? _manualMismatch(
    List<DescribedColumn> declared,
    List<DescribedColumn> live,
  ) {
    if (declared.length != live.length) {
      return 'declares ${declared.length} column(s); the server describes '
          '${live.length}.';
    }
    for (var i = 0; i < declared.length; i++) {
      final a = declared[i];
      final b = live[i];
      if (a.name.toLowerCase() != b.name.toLowerCase()) {
        return 'column ${i + 1} is declared "${a.name}"; the server calls it '
            '"${b.name}".';
      }
      if (a.sqlTypeName.toLowerCase() != b.sqlTypeName.toLowerCase()) {
        return 'column "${a.name}" is declared ${a.sqlTypeName}; the server '
            'reports ${b.sqlTypeName}.';
      }
      if (a.nullable != b.nullable) {
        return 'column "${a.name}" is declared '
            '${a.nullable ? 'nullable' : 'not null'}; the server reports '
            '${b.nullable ? 'nullable' : 'not null'}.';
      }
    }
    return null;
  }

  /// The `@params` text sp_describe_first_result_set needs to compile the
  /// statement, or null when there is nothing to declare.
  ///
  /// A procedure call spells its arguments out in [_describeText] and has no
  /// free variables, so it declares nothing here.
  String? _paramsDeclaration(
    QueryDefinition definition,
    List<DescribedParameter> parameters,
  ) {
    if (definition.procedure != null) return null;
    final declared = <String, DeclaredParameter>{
      for (final p in definition.parameters) p.name.toLowerCase(): p,
    };
    final parts = <String>[];
    for (final parameter in parameters) {
      final type =
          parameter.declaration ??
          declared[parameter.name.toLowerCase()]?.declaration ??
          parameter.sqlTypeName;
      final source = declared[parameter.name.toLowerCase()];
      final tableType = source?.tableType;
      if (tableType != null) {
        parts.add('@${parameter.name} $tableType READONLY');
        continue;
      }
      final output = source?.direction == QueryParameterDirection.output;
      parts.add('@${parameter.name} $type${output ? ' OUTPUT' : ''}');
    }
    if (parts.isEmpty) return null;
    return parts.join(', ');
  }

  String _describeText(QueryDefinition definition) {
    final procedure = definition.procedure;
    if (procedure == null) return definition.sql;
    final arguments = definition.parameters
        .where((p) => p.tableType == null)
        .map((p) => '@${p.name} = NULL')
        .join(', ');
    return 'EXEC ${MssqlMultipartIdentifier.parse(procedure).quoted}'
        '${arguments.isEmpty ? '' : ' $arguments'}';
  }

  /// Names the case that applies, so the fix is obvious.
  String _reasonFor(QueryDefinition definition, MssqlException error) {
    if (error.type == MssqlErrorType.connection ||
        error.type == MssqlErrorType.connectionLost ||
        error.type == MssqlErrorType.authentication) {
      return 'Could not describe ${definition.sourcePath}: the database '
          'connection failed (${error.type.name}).';
    }
    // Check the specific cases before the generic syntax message: a temp
    // table, a dynamic EXEC and a missing object all arrive as
    // MssqlErrorType.querySyntax, so a generic "invalid SQL" first would hide
    // the actual cause.
    final sql = definition.sql.toLowerCase();
    if (RegExp(r'(^|[^\w#])#\w').hasMatch(sql)) {
      return 'The query uses a temporary table. sp_describe_first_result_set '
          'compiles without running, so the #table does not exist yet. '
          'Declare the shape with "-- describe: manual" and "-- column:" '
          'directives.';
    }
    if (sql.contains('sp_executesql')) {
      return 'The query runs SQL dynamically through sp_executesql, so it '
          'has no fixed shape to describe. Declare the shape with '
          '"-- describe: manual", or write the statement out literally.';
    }
    if (RegExp(r'\bexec(ute)?\s*\(').hasMatch(sql)) {
      return 'The query builds SQL dynamically from a variable, so it has no '
          'fixed shape to describe. A literal EXEC would be describable.';
    }
    if (definition.procedure != null) {
      return 'The procedure does not always return the same first result set, '
          'so SQL Server will not commit to one shape.';
    }
    if (error.type == MssqlErrorType.querySyntax) {
      return 'SQL Server could not determine a single result shape for '
          '${definition.sourcePath}'
          '${definition.sqlLine == null ? '' : ' at line ${definition.sqlLine}'}'
          ', and rejected the statement as invalid SQL. A name it cannot '
          'resolve reads the same way as a typo here.';
    }
    return 'SQL Server could not determine a single result shape.';
  }

  /// Whether [sql] references a parameter at all.
  ///
  /// `@@IDENTITY` and friends are server variables rather than parameters, so
  /// a doubled `@` does not count; neither does an `@` inside a quoted
  /// string, which is why the scan skips literals.
  /// Every `@name` the statement mentions, lower-cased.
  ///
  /// `@@rowcount` and friends are not parameters, and an `@` inside a string
  /// literal or a bracketed identifier is not one either.
  static Set<String> _mentionedParameters(String sql) {
    final out = <String>{};
    var inString = false;
    var inBracket = false;
    for (var i = 0; i < sql.length; i++) {
      final c = sql[i];
      if (inString) {
        if (c == "'") inString = false;
        continue;
      }
      if (inBracket) {
        if (c == ']') inBracket = false;
        continue;
      }
      if (c == "'") {
        inString = true;
        continue;
      }
      if (c == '[') {
        inBracket = true;
        continue;
      }
      if (c != '@') continue;
      if (i + 1 < sql.length && sql[i + 1] == '@') {
        i++;
        continue;
      }
      var end = i + 1;
      while (end < sql.length && RegExp(r'[A-Za-z0-9_]').hasMatch(sql[end])) {
        end++;
      }
      if (end > i + 1 && RegExp(r'[A-Za-z_]').hasMatch(sql[i + 1])) {
        out.add(sql.substring(i + 1, end).toLowerCase());
      }
      i = end - 1;
    }
    return out;
  }

  static bool _mentionsParameter(String sql) {
    var inString = false;
    var inBracket = false;
    for (var i = 0; i < sql.length; i++) {
      final c = sql[i];
      if (inString) {
        if (c == "'") inString = false;
        continue;
      }
      if (inBracket) {
        if (c == ']') inBracket = false;
        continue;
      }
      if (c == "'") {
        inString = true;
        continue;
      }
      if (c == '[') {
        inBracket = true;
        continue;
      }
      if (c != '@') continue;
      if (i + 1 < sql.length && sql[i + 1] == '@') {
        i++;
        continue;
      }
      if (i + 1 < sql.length && RegExp(r'[A-Za-z_]').hasMatch(sql[i + 1])) {
        return true;
      }
    }
    return false;
  }

  String _parameterReason(MssqlException error) {
    if (error.type == MssqlErrorType.connection ||
        error.type == MssqlErrorType.connectionLost ||
        error.type == MssqlErrorType.authentication) {
      return 'Could not describe parameters: the database connection failed '
          '(${error.type.name}).';
    }
    if (error.type == MssqlErrorType.querySyntax) {
      return 'SQL Server rejected the statement while describing parameters. '
          'This is not "the query has no parameters".';
    }
    return 'SQL Server could not describe undeclared parameters. This is not '
        'treated as an empty parameter list.';
  }
}

DescribedQuery describeManual(QueryDefinition definition) {
  return DescribedQuery(
    definition: definition,
    columns: <DescribedColumn>[
      for (var i = 0; i < definition.manualColumns!.length; i++)
        _manualColumn(definition.manualColumns![i], i + 1),
    ],
    parameters: <DescribedParameter>[
      for (final p in definition.parameters) _declaredParameter(p),
    ],
  );
}

DescribedColumn _manualColumn(ManualColumn column, int ordinal) {
  return DescribedColumn(
    ordinal: ordinal,
    name: column.name,
    sqlTypeName: column.sqlTypeName,
    nullable: column.nullable,
    maxLength: column.maxLength,
    precision: column.precision,
    scale: column.scale,
  );
}

DescribedParameter _declaredParameter(DeclaredParameter parameter) {
  return DescribedParameter(
    name: parameter.name,
    sqlTypeName: parameter.sqlTypeName,
    nullable: parameter.nullable,
    declaration: parameter.declaration ?? parameter.sqlTypeName,
    maxLength: parameter.maxLength,
    precision: parameter.precision,
    scale: parameter.scale,
  );
}

SqlTypeSpec _specFromServer(String systemTypeName) {
  try {
    return SqlTypeSpec.parse(systemTypeName);
  } on FormatException {
    return SqlTypeSpec(
      baseName: _baseTypeName(systemTypeName),
      declaration: systemTypeName.toLowerCase(),
    );
  }
}

/// `nvarchar(50)` and `decimal(18,4)` reduce to `nvarchar` and `decimal`.
String _baseTypeName(String systemTypeName) {
  final open = systemTypeName.indexOf('(');
  final name = open < 0 ? systemTypeName : systemTypeName.substring(0, open);
  return name.trim().toLowerCase();
}

bool _bool(Object? value) => switch (value) {
  final bool b => b,
  final num n => n != 0,
  final String s => s == '1' || s.toLowerCase() == 'true',
  _ => false,
};
