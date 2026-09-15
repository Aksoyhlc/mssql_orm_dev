import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'naming.dart';
import 'sql_type_spec.dart';

/// How many rows a query is declared to return.
enum QueryShape {
  list,
  single,
  singleOrNull,

  /// One column of one row. Nullability comes from that column's metadata.
  scalar,

  /// No result set: an INSERT, UPDATE, DELETE or a procedure called for effect.
  affected,
}

/// A column declared by hand, for a query SQL Server cannot describe.
@immutable
class ManualColumn {
  const ManualColumn({
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
  final String? declaration;
  final int maxLength;
  final int precision;
  final int scale;
}

/// A parameter whose type the file states rather than leaving to inference.
@immutable
class DeclaredParameter {
  const DeclaredParameter({
    required this.name,
    required this.sqlTypeName,
    this.nullable = false,
    this.declaration,
    this.maxLength = 0,
    this.precision = 0,
    this.scale = 0,
    this.direction = QueryParameterDirection.input,
    this.hasDefault = false,
    this.tableType,
  });

  final String name;
  final String sqlTypeName;
  final bool nullable;
  final String? declaration;
  final int maxLength;
  final int precision;
  final int scale;
  final QueryParameterDirection direction;
  final bool hasDefault;

  /// Qualified table type for a TVP, such as `dbo.OrderLineType`.
  final String? tableType;
}

enum QueryParameterDirection { input, output, inputOutput }

enum QueryExtraSets { error, ignore }

/// One extra result set declared by hand. Set 0 may still come from describe.
@immutable
class DeclaredResultSet {
  const DeclaredResultSet({required this.name, required this.columns});
  final String name;
  final List<ManualColumn> columns;
}

/// One `.sql` file, parsed.
@immutable
class QueryDefinition {
  const QueryDefinition({
    required this.name,
    required this.sql,
    required this.sourcePath,
    this.sourceHash = '',
    this.sqlLine,
    this.procedure,
    this.parameters = const <DeclaredParameter>[],
    this.shape = QueryShape.list,
    this.notNullColumns = const <String>{},
    this.manualColumns,
    this.readOnly = false,
    this.firstResultSetName,
    this.extraResultSets = const <DeclaredResultSet>[],
    this.extraSets = QueryExtraSets.error,
    this.tvpColumns = const <String, List<ManualColumn>>{},
  });

  /// The generated method's name.
  final String name;

  /// The statement text, with the directive comments stripped.
  final String sql;

  final String sourcePath;

  /// SHA-256 of the file bytes, so offline generation can refuse a SQL
  /// file that moved since its described shape was cached.
  final String sourceHash;

  /// 1-based line where the SQL body starts, for diagnostics.
  final int? sqlLine;

  /// Set when the file describes a stored procedure instead of a statement.
  final String? procedure;

  final List<DeclaredParameter> parameters;
  final QueryShape shape;

  /// Columns the author asserts are never null.
  final Set<String> notNullColumns;

  /// Non-null when `-- describe: manual` was given: the columns as declared.
  final List<ManualColumn>? manualColumns;

  /// Explicit `-- read_only:` opt-in. Never inferred from returning rows.
  final bool readOnly;

  /// Dart name of the first result set when `-- describe: manual` named it
  /// with `-- resultset:` before its columns.
  final String? firstResultSetName;

  /// Result sets after the first, which `sp_describe_first_result_set` cannot
  /// see. Always manual.
  final List<DeclaredResultSet> extraResultSets;

  /// What to do when the procedure returns more sets than were declared.
  final QueryExtraSets extraSets;

  /// TVP column shapes, keyed by parameter name.
  final Map<String, List<ManualColumn>> tvpColumns;

  bool get isManual => manualColumns != null;

  /// What to hand `sp_describe_first_result_set`: the procedure name, or the
  /// statement itself.
  String get describeTarget => procedure ?? sql;
}

/// Raised for a `.sql` file that cannot be acted on.
class QueryFileError implements Exception {
  const QueryFileError(this.path, this.message, {this.line});

  final String path;
  final int? line;
  final String message;

  @override
  String toString() =>
      'QueryFileError: $path${line == null ? '' : ':$line'} — $message';
}

const Set<String> _directives = <String>{
  'name',
  'param',
  'returns',
  'notnull',
  'procedure',
  'describe',
  'column',
  'read_only',
  'output',
  'inout',
  'tvp',
  'tvp_column',
  'resultset',
  'extra_sets',
};

/// Parses one `.sql` file.
///
/// Directives are leading `--` comments only.
QueryDefinition parseQueryFile(String path, String contents) {
  final lines = contents.split('\n');
  String? name;
  String? procedure;
  var shape = QueryShape.list;
  final parameters = <DeclaredParameter>[];
  final notNull = <String>{};
  final columns = <ManualColumn>[];
  var manual = false;
  final extraSets = <DeclaredResultSet>[];
  final extraSetColumns = <ManualColumn>[];
  String? extraSetName;
  final tvpColumns = <String, List<ManualColumn>>{};
  var extraSetsPolicy = QueryExtraSets.error;
  var readOnly = false;
  var index = 0;

  Never fail(String message, [int? line]) =>
      throw QueryFileError(path, message, line: line);

  for (; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    if (!line.startsWith('--')) break;

    final body = line.substring(2).trim();
    final colon = body.indexOf(':');
    if (colon < 0) continue; // An ordinary comment.
    final key = body.substring(0, colon).trim().toLowerCase();
    final value = body.substring(colon + 1).trim();
    if (!_directives.contains(key)) continue; // Also an ordinary comment.
    if (value.isEmpty) fail('The $key directive has no value.', index + 1);

    switch (key) {
      case 'name':
        if (name != null) fail('Two name directives.', index + 1);
        name = value;
      case 'procedure':
        procedure = value;
      case 'returns':
        shape = switch (value.toLowerCase()) {
          'list' => QueryShape.list,
          'single' => QueryShape.single,
          'single_or_null' => QueryShape.singleOrNull,
          'scalar' => QueryShape.scalar,
          'affected' => QueryShape.affected,
          _ => fail(
            'returns must be list, single, single_or_null, scalar or '
            'affected, not "$value".',
            index + 1,
          ),
        };
      case 'notnull':
        notNull.addAll(value.split(',').map((v) => v.trim()));
      case 'describe':
        if (value.toLowerCase() != 'manual') {
          fail('describe takes only "manual".', index + 1);
        }
        manual = true;
      case 'param':
        parameters.add(_parseParameter(value, path, index + 1));
      case 'output':
        parameters.add(
          _parseParameter(
            value,
            path,
            index + 1,
            direction: QueryParameterDirection.output,
          ),
        );
      case 'inout':
        parameters.add(
          _parseParameter(
            value,
            path,
            index + 1,
            direction: QueryParameterDirection.inputOutput,
          ),
        );
      case 'tvp':
        parameters.add(_parseTvp(value, path, index + 1));
      case 'tvp_column':
        _addTvpColumn(tvpColumns, value, path, index + 1);
      case 'resultset':
        if (extraSetName != null) {
          extraSets.add(
            DeclaredResultSet(
              name: extraSetName,
              columns: extraSetColumns.toList(),
            ),
          );
          extraSetColumns.clear();
        }
        extraSetName = fieldName(value);
      case 'extra_sets':
        extraSetsPolicy = switch (value.toLowerCase()) {
          'error' => QueryExtraSets.error,
          'ignore' => QueryExtraSets.ignore,
          _ => fail(
            'extra_sets must be error or ignore, not "$value".',
            index + 1,
          ),
        };
      case 'column':
        final column = _parseColumn(value, path, index + 1);
        if (extraSetName != null) {
          extraSetColumns.add(column);
        } else {
          columns.add(column);
        }
      case 'read_only':
        final folded = value.toLowerCase();
        if (folded != 'true' && folded != 'yes') {
          fail(
            'read_only takes "true". Returning rows does not make a '
            'statement safe to retry.',
            index + 1,
          );
        }
        readOnly = true;
    }
  }

  if (name == null) {
    fail(
      'No "-- name:" directive. The method name is stated rather than taken '
      'from the file name, so renaming the file cannot silently rename the '
      'method and break its callers.',
    );
  }

  if (extraSetName != null) {
    extraSets.add(
      DeclaredResultSet(
        name: extraSetName,
        columns: List<ManualColumn>.from(extraSetColumns),
      ),
    );
  }

  String? firstResultSetName;
  if (manual && columns.isEmpty && extraSets.isNotEmpty) {
    final first = extraSets.removeAt(0);
    firstResultSetName = first.name;
    columns.addAll(first.columns);
  }

  if (manual && columns.isEmpty) {
    fail('describe: manual needs at least one "-- column:" directive.');
  }
  if (!manual && columns.isNotEmpty) {
    fail('"-- column:" is only meaningful with "-- describe: manual".');
  }

  final sql = lines.skip(index).join('\n').trim();
  if (sql.isEmpty && procedure == null) {
    fail('The file has no SQL and names no procedure.');
  }

  final procedureOnly =
      extraSets.isNotEmpty ||
      extraSetsPolicy != QueryExtraSets.error ||
      parameters.any(
        (p) =>
            p.tableType != null || p.direction != QueryParameterDirection.input,
      );
  if (procedureOnly && procedure == null) {
    fail(
      '-- procedure: is required for output, inout, tvp, resultset and '
      'extra_sets. Those apply to callProcedure, not to a statement.',
    );
  }
  for (final set in extraSets) {
    if (set.columns.isEmpty) {
      fail(
        'Result set "${set.name}" has no "-- column:" directives. '
        'sp_describe_first_result_set cannot see sets after the first.',
      );
    }
  }
  for (final parameter in parameters) {
    if (parameter.tableType == null) continue;
    final owned = tvpColumns[parameter.name];
    if (owned == null || owned.isEmpty) {
      fail(
        'TVP "${parameter.name}" needs -- tvp_column: ${parameter.name} '
        'Col type so rows can be typed.',
      );
    }
  }

  return QueryDefinition(
    name: name,
    sql: sql,
    sourcePath: path,
    sourceHash: sha256.convert(utf8.encode(contents)).toString(),
    sqlLine: index + 1,
    procedure: procedure,
    parameters: parameters,
    shape: shape,
    notNullColumns: notNull,
    manualColumns: manual ? columns : null,
    readOnly: readOnly,
    firstResultSetName: firstResultSetName,
    extraResultSets: extraSets,
    extraSets: extraSetsPolicy,
    tvpColumns: tvpColumns,
  );
}

DeclaredParameter _parseParameter(
  String value,
  String path,
  int line, {
  QueryParameterDirection direction = QueryParameterDirection.input,
}) {
  var rest = value.trim();
  var hasDefault = false;
  var resolvedDirection = direction;
  final tokens = rest.split(RegExp(r'\s+'));
  while (tokens.isNotEmpty) {
    final last = tokens.last.toLowerCase();
    if (last == 'default') {
      hasDefault = true;
      tokens.removeLast();
    } else if (last == 'output') {
      resolvedDirection = QueryParameterDirection.output;
      tokens.removeLast();
    } else if (last == 'inout' || last == 'in_out') {
      resolvedDirection = QueryParameterDirection.inputOutput;
      tokens.removeLast();
    } else {
      break;
    }
  }
  rest = tokens.join(' ');
  final parsed = _splitNameTypeNull(rest, defaultNullable: false);
  if (parsed == null) {
    throw QueryFileError(
      path,
      'param needs a name and a SQL type, as in "customerId int" or '
      '"note nvarchar(50) null".',
      line: line,
    );
  }
  final spec = _typeOrThrow(parsed.type, path, line);
  return DeclaredParameter(
    name: parsed.name.startsWith('@') ? parsed.name.substring(1) : parsed.name,
    sqlTypeName: spec.baseName,
    nullable: parsed.nullable,
    declaration: spec.declaration,
    maxLength: spec.maxLength,
    precision: spec.precision,
    scale: spec.scale,
    direction: resolvedDirection,
    hasDefault: hasDefault,
  );
}

DeclaredParameter _parseTvp(String value, String path, int line) {
  final parts = value.split(RegExp(r'\s+'));
  if (parts.length < 2) {
    throw QueryFileError(
      path,
      'tvp needs a parameter name and a table type, as in '
      '"lines dbo.OrderLineType".',
      line: line,
    );
  }
  final rawName = parts[0].startsWith('@') ? parts[0].substring(1) : parts[0];
  return DeclaredParameter(
    name: rawName,
    sqlTypeName: 'table',
    tableType: parts[1],
  );
}

void _addTvpColumn(
  Map<String, List<ManualColumn>> tvpColumns,
  String value,
  String path,
  int line,
) {
  final space = value.indexOf(' ');
  if (space < 0) {
    throw QueryFileError(
      path,
      'tvp_column needs a parameter name and a column, as in '
      '"lines Id int not null".',
      line: line,
    );
  }
  var owner = value.substring(0, space);
  if (owner.startsWith('@')) owner = owner.substring(1);
  final column = _parseColumn(value.substring(space + 1).trim(), path, line);
  tvpColumns.putIfAbsent(owner, () => <ManualColumn>[]).add(column);
}

ManualColumn _parseColumn(String value, String path, int line) {
  final parsed = _splitNameTypeNull(value, defaultNullable: true);
  if (parsed == null) {
    throw QueryFileError(
      path,
      'column needs a name and a SQL type, as in "Id int not null".',
      line: line,
    );
  }
  final spec = _typeOrThrow(parsed.type, path, line);
  return ManualColumn(
    name: parsed.name,
    sqlTypeName: spec.baseName,
    nullable: parsed.nullable,
    declaration: spec.declaration,
    maxLength: spec.maxLength,
    precision: spec.precision,
    scale: spec.scale,
  );
}

class _NameTypeNull {
  const _NameTypeNull(this.name, this.type, this.nullable);
  final String name;
  final String type;
  final bool nullable;
}

_NameTypeNull? _splitNameTypeNull(
  String value, {
  required bool defaultNullable,
}) {
  final match = RegExp(
    r'^(@?[A-Za-z_][A-Za-z0-9_]*)\s+'
    r'([A-Za-z][A-Za-z0-9_]*(?:\s*\([^)]+\))?)\s*'
    r'(null|not\s+null)?\s*$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final nullability = (match.group(3) ?? '').toLowerCase().replaceAll(' ', '');
  final nullable = nullability == 'notnull'
      ? false
      : nullability == 'null'
      ? true
      : defaultNullable;
  return _NameTypeNull(match.group(1)!, match.group(2)!, nullable);
}

SqlTypeSpec _typeOrThrow(String type, String path, int line) {
  try {
    return SqlTypeSpec.parse(type);
  } on FormatException catch (error) {
    throw QueryFileError(path, error.message, line: line);
  }
}
