import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Raised for a configuration file that cannot be acted on.
///
/// The generator writes nothing when this is thrown: a partial or guessed
/// result is worse than none.
class ConfigError implements Exception {
  const ConfigError(this.message);
  final String message;
  @override
  String toString() => 'ConfigError: $message';
}

/// A configuration that is well-formed but names a secret the environment
/// does not hold.
///
/// Its own type so `requireSecrets: false` falls back to offline generation
/// for this case alone, and an invalid port or a misspelled key still stops
/// the run.
class MissingSecretError extends ConfigError {
  const MissingSecretError(super.message);
}

class TimestampColumnsConfig {
  const TimestampColumnsConfig({this.createdColumn, this.updatedColumn});

  final String? createdColumn;
  final String? updatedColumn;
}

/// The column names looked for on every table, unless a table says otherwise.
///
/// Matches case-insensitively after stripping underscores and spaces.
class ConventionsConfig {
  const ConventionsConfig({
    this.softDelete = 'deleted_at',
    this.createdAt = 'created_at',
    this.updatedAt = 'updated_at',
  });

  /// Null disables the convention: no table gets a soft delete it did not ask
  /// for by name.
  final String? softDelete;
  final String? createdAt;
  final String? updatedAt;

  /// Whether [columnName] is the column [convention] means.
  static bool matches(String columnName, String convention) =>
      _fold(columnName) == _fold(convention);

  static String _fold(String value) =>
      value.replaceAll('_', '').replaceAll(' ', '').toLowerCase();
}

/// A per-table or per-column setting, looked up by the catalog's own path.
///
/// Keys match case-insensitively, with or without the leading schema.
class KeyedSetting<T> {
  KeyedSetting(this.setting, Map<String, T> entries)
    : _values = <String, T>{
        for (final entry in entries.entries) _fold(entry.key): entry.value,
      },
      _spelling = <String, String>{
        for (final key in entries.keys) _fold(key): key,
      };

  /// The configuration key this came from, named in the report.
  final String setting;

  final Map<String, T> _values;
  final Map<String, String> _spelling;
  final Set<String> _used = <String>{};

  bool get isEmpty => _values.isEmpty;

  /// The value set for [path], or null. [path] is the catalog's own spelling:
  /// `dbo.Orders`, or `dbo.Orders.CustomerId`.
  T? operator [](String path) {
    for (final candidate in _candidates(path)) {
      if (!_values.containsKey(candidate)) continue;
      _used.add(candidate);
      return _values[candidate];
    }
    return null;
  }

  /// Whether [path] has an entry at all, which is not the same as having a
  /// non-null value: `soft_delete_columns` uses null to mean "not this table".
  bool contains(String path) {
    for (final candidate in _candidates(path)) {
      if (_values.containsKey(candidate)) {
        _used.add(candidate);
        return true;
      }
    }
    return false;
  }

  /// The keys, in the spelling they were written.
  Iterable<String> get keys => _spelling.values;

  Iterable<MapEntry<String, T>> get entries => <MapEntry<String, T>>[
    for (final entry in _values.entries)
      MapEntry<String, T>(_spelling[entry.key]!, entry.value),
  ];

  /// Whether [key] — a configuration key — names [path], the catalog's own
  /// spelling. The same rule [operator []] uses, for the checks that verify a
  /// key resolves before anything is generated.
  static bool matches(String key, String path) =>
      _candidates(path).contains(_fold(key));

  /// Keys no table or column ever matched, in the spelling they were written.
  List<String> get unmatchedKeys => <String>[
    for (final key in _values.keys)
      if (!_used.contains(key)) _spelling[key]!,
  ]..sort();

  static Iterable<String> _candidates(String path) sync* {
    final folded = _fold(path);
    yield folded;
    // The same path with its schema dropped, so `Orders` finds `dbo.Orders`.
    final dot = folded.indexOf('.');
    if (dot > 0) yield folded.substring(dot + 1);
  }

  static String _fold(String value) => value.trim().toLowerCase();
}

/// Everything the generator reads from `mssql_orm.yaml`.
class GeneratorConfig {
  GeneratorConfig({
    required this.connection,
    required this.output,
    required this.modelsOutput,
    required this.queriesInput,
    required this.snapshotPath,
    String? extensionsOutput,
    this.databaseClass = 'AppDatabase',
    required this.schemas,
    this.scaffold = true,
    this.includeViews = true,
    this.include = const <String>['*'],
    this.exclude = const <String>['sysdiagrams'],
    this.decimalMode = MssqlDecimalMode.exact,
    this.json = false,
    Map<String, String> classNames = const <String, String>{},
    Map<String, String> fieldNames = const <String, String>{},
    Map<String, String> queryMethods = const <String, String>{},
    this.readOnlyColumns = const <String>[],
    this.hiddenColumns = const <String>[],
    this.conventions = const ConventionsConfig(),
    Map<String, String?> softDeleteColumns = const <String, String?>{},
    Map<String, String?> hierarchyParents = const <String, String?>{},
    Map<String, TimestampColumnsConfig> timestampColumns =
        const <String, TimestampColumnsConfig>{},
    Map<String, String> relationNames = const <String, String>{},
    this.excludedRelations = const <String>[],
    this.declaredRelations = const <DeclaredRelationConfig>[],
    this.projections = const <ProjectionConfig>[],
    this.enumColumns = const <String, EnumColumnConfig>{},
    this.converters = const <String, ConverterColumnConfig>{},
    this.connectionConfigured = true,
    this.warnings = const <String>[],
  }) : classNames = KeyedSetting<String>('class_names', classNames),
       fieldNames = KeyedSetting<String>('field_names', fieldNames),
       queryMethods = KeyedSetting<String>('query_methods', queryMethods),
       softDeleteColumns = KeyedSetting<String?>(
         'soft_delete_columns',
         softDeleteColumns,
       ),
       hierarchyParents = KeyedSetting<String?>(
         'hierarchy_parents',
         hierarchyParents,
       ),
       timestampColumns = KeyedSetting<TimestampColumnsConfig>(
         'timestamps',
         timestampColumns,
       ),
       relationNames = KeyedSetting<String>('relation_names', relationNames),
       // Derived from [output] so the path stays correct when driven
       // programmatically from a different working directory.
       extensionsOutput =
           extensionsOutput ?? p.join(p.dirname(output), 'extensions');

  final MssqlConnectionConfig connection;

  /// Rewritten wholesale on every run.
  final String output;

  /// Written once per table and never touched again.
  final String modelsOutput;

  /// User-owned query scope extensions, written once and never overwritten.
  /// Defaults to a sibling of [output].
  final String extensionsOutput;

  /// Generated entry class, `AppDatabase` unless the configuration says
  /// otherwise.
  final String databaseClass;

  /// Where hand-written `.sql` files live.
  final String queriesInput;

  /// Where the schema snapshot is written and read.
  final String snapshotPath;

  final Set<String> schemas;
  final bool scaffold;
  final bool includeViews;
  final List<String> include;
  final List<String> exclude;
  final MssqlDecimalMode decimalMode;
  final bool json;

  /// Keyed `schema.Table`, or just `Table`.
  final KeyedSetting<String> classNames;

  /// Keyed `schema.Table.Column`, or just `Table.Column`.
  final KeyedSetting<String> fieldNames;

  /// Override for a generated `whereX` name, keyed like [fieldNames].
  final KeyedSetting<String> queryMethods;

  /// Patterns as `schema.Table.Column`, or `*.Column` for every table.
  final List<String> readOnlyColumns;
  final List<String> hiddenColumns;

  /// Keyed by `schema.Table`, valued with its nullable deleted-at column.
  /// The names looked for when a table says nothing.
  final ConventionsConfig conventions;

  /// Per-table answers that beat the convention.
  /// A null value means "this table does not soft-delete".
  final KeyedSetting<String?> softDeleteColumns;

  /// Which column holds the parent key, per table, for a generated
  /// `descendantsOf` walk. Only needed when a table has more than one
  /// self-referencing foreign key.
  final KeyedSetting<String?> hierarchyParents;

  /// Keyed by `schema.Table`, or just `Table`.
  final KeyedSetting<TimestampColumnsConfig> timestampColumns;

  /// Keyed `schema.Table.derivedName`, valued with the name to use instead.
  final KeyedSetting<String> relationNames;

  /// Every per-table setting, so the run can report the keys that matched
  /// nothing.
  List<KeyedSetting<Object?>> get keyedSettings => <KeyedSetting<Object?>>[
    classNames,
    fieldNames,
    queryMethods,
    softDeleteColumns,
    hierarchyParents,
    timestampColumns,
    relationNames,
  ];

  /// `schema.Table.relationName` entries to leave ungenerated.
  final List<String> excludedRelations;

  /// Explicit belongsToMany / through / morph relations. Never inferred
  /// from "this table has two foreign keys".
  final List<DeclaredRelationConfig> declaredRelations;

  /// Named DTO projections keyed in YAML under `projections:`.
  final List<ProjectionConfig> projections;

  /// Explicit enum mappings. String columns are not turned into enums
  /// unless named here.
  final Map<String, EnumColumnConfig> enumColumns;

  /// Explicit Dart type + converter class for a column.
  final Map<String, ConverterColumnConfig> converters;

  /// Whether live credentials were resolved. False when env vars are
  /// missing and the load asked not to require them.
  final bool connectionConfigured;

  /// Things worth saying out loud that are not fatal.
  final List<String> warnings;

  static GeneratorConfig load(
    String path, {
    Map<String, String>? environment,
    bool requireSecrets = true,
  }) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigError('No configuration file at $path.');
    }
    final parsed = loadYaml(file.readAsStringSync());
    if (parsed is! YamlMap) {
      throw ConfigError('$path does not contain a YAML mapping.');
    }
    return fromMap(
      parsed,
      basePath: '.',
      environment: environment ?? Platform.environment,
      requireSecrets: requireSecrets,
    );
  }

  /// [basePath] is what relative output paths resolve against, and it is the
  /// working directory rather than the configuration file's own — see [load].
  static GeneratorConfig fromMap(
    Map<Object?, Object?> map, {
    String basePath = '.',
    Map<String, String> environment = const <String, String>{},
    bool requireSecrets = true,
  }) {
    final warnings = <String>[];
    final connectionMap = map['connection'];
    if (connectionMap is! Map) {
      throw const ConfigError('The configuration needs a "connection" block.');
    }
    _rejectUnknownKeys(
      connectionMap,
      _connectionKeys,
      'connection',
      'A key this generator does not read is a setting that looks applied and '
          'is not — which is how a build ends up connecting differently from '
          'the file that describes it.',
    );

    String resolve(String key, {bool secret = false}) {
      final raw = connectionMap[key];
      if (raw == null) {
        throw MissingSecretError('connection.$key is missing.');
      }
      return _resolveSecret(
        key,
        raw.toString(),
        environment,
        warnings,
        secret: secret,
      );
    }

    // A connection string is what anyone arriving from .NET already has.
    final connectionString = connectionMap['from'];
    if (connectionString != null) {
      for (final key in <String>[
        'host',
        'port',
        'database',
        'user',
        'password',
        'encrypt',
        'trust_server_certificate',
      ]) {
        if (connectionMap[key] == null) continue;
        throw ConfigError(
          'connection.from is a whole connection string, so connection.$key '
          'has nothing to add. Remove one of the two.',
        );
      }
      try {
        final resolved = _resolveSecret(
          'from',
          connectionString.toString(),
          environment,
          warnings,
          secret: true,
        );
        return _build(
          map,
          MssqlConnectionConfig.fromConnectionString(
            resolved,
            decimalMode: _decimalMode(map['decimal_mode']),
            onUnsupportedKeys: (keys) => warnings.add(
              'connection.from carries ${keys.join(', ')}, which this driver '
              'has no use for. They were ignored.',
            ),
          ),
          basePath,
          warnings,
          connectionConfigured: true,
        );
      } on MissingSecretError {
        if (requireSecrets) rethrow;
        return _build(
          map,
          _offlineConnection(map),
          basePath,
          warnings,
          connectionConfigured: false,
        );
      }
    }

    // Port is resolved like every other connection key.
    int? readPort() {
      if (connectionMap['port'] == null) return null;
      final text = resolve('port');
      final value = int.tryParse(text.trim());
      if (value == null || value <= 0 || value > 65535) {
        throw ConfigError(
          'connection.port is "$text", which is not a TCP port. Give a '
          'number between 1 and 65535, or leave it out for 1433.',
        );
      }
      return value;
    }

    // A value that cannot be honoured is refused rather than downgraded: a
    // file asking for an encrypted session must not produce a plaintext one.
    MssqlEncryption readEncryption() {
      final raw = connectionMap['encrypt'];
      if (raw == null) return MssqlEncryption.off;
      final text = _resolveSecret(
        'encrypt',
        raw.toString(),
        environment,
        warnings,
      ).trim().toLowerCase();
      return switch (text) {
        'off' || 'false' || 'no' => MssqlEncryption.off,
        'request' => MssqlEncryption.request,
        'on' || 'true' || 'yes' || 'require' => MssqlEncryption.require,
        'strict' => MssqlEncryption.strict,
        _ => throw ConfigError(
          'connection.encrypt is "$text". Use off, request, require or '
          'strict.',
        ),
      };
    }

    if (connectionMap['trust_server_certificate'] != null) {
      throw const ConfigError(
        'connection.trust_server_certificate cannot be honoured here. FreeTDS '
        'decides certificate trust once for the whole process, not per '
        'connection, so it is configured through '
        'MssqlRuntime.initialize(tls: ...) in the application — see the '
        "driver's doc/TLS.md. Remove the key once that is in place, so the "
        'configuration stops claiming a guarantee it does not get.',
      );
    }

    try {
      final port = readPort();
      final connection = MssqlConnectionConfig(
        host: resolve('host'),
        port: port ?? 1433,
        database: resolve('database'),
        username: resolve('user'),
        password: resolve('password', secret: true),
        encryption: readEncryption(),
        decimalMode: _decimalMode(map['decimal_mode']),
        defaultQueryTimeout: const Duration(seconds: 60),
      );
      return _build(
        map,
        connection,
        basePath,
        warnings,
        connectionConfigured: true,
      );
    } on MissingSecretError {
      if (requireSecrets) rethrow;
      return _build(
        map,
        _offlineConnection(map),
        basePath,
        warnings,
        connectionConfigured: false,
      );
    }
  }
}

/// Every key the root of the configuration understands.
const Set<String> _rootKeys = <String>{
  'class_names',
  'connection',
  'conventions',
  'converters',
  'database_class',
  'decimal_mode',
  'declared_relations',
  'enum_columns',
  'exclude',
  'exclude_relations',
  'extensions_output',
  'field_names',
  'hidden_columns',
  'hierarchy_parents',
  'include',
  'include_views',
  'json',
  'models_output',
  'output',
  'projections',
  'queries_input',
  'query_methods',
  'readonly_columns',
  'relation_names',
  'scaffold',
  'schemas',
  'snapshot',
  'soft_delete_columns',
  'timestamps',
};

/// Every key the `connection` block understands.
const Set<String> _connectionKeys = <String>{
  'from',
  'host',
  'port',
  'database',
  'user',
  'password',
  'encrypt',
  'trust_server_certificate',
};

/// Refuses keys nothing reads, naming the nearest known spelling.
///
/// A key that looks applied and is not generates code the file does not
/// describe: `scafold:` leaves scaffolding on its default, and so does
/// `outut:`.
void _rejectUnknownKeys(
  Map<Object?, Object?> map,
  Set<String> known,
  String where,
  String why,
) {
  final unknown = <String>[
    for (final key in map.keys)
      if (!known.contains(key.toString())) key.toString(),
  ]..sort();
  if (unknown.isEmpty) return;
  final details = <String>[
    for (final key in unknown)
      switch (_nearest(key, known)) {
        final String near => '"$key" (did you mean "$near"?)',
        _ => '"$key"',
      },
  ];
  throw ConfigError('$where does not understand ${details.join(', ')}. $why');
}

/// The known key within one edit of [key], or null.
String? _nearest(String key, Set<String> known) {
  for (final candidate in known) {
    if (_withinOneEdit(key, candidate)) return candidate;
  }
  return null;
}

bool _withinOneEdit(String a, String b) {
  if (a == b) return true;
  if ((a.length - b.length).abs() > 1) return false;
  if (a.length == b.length) {
    var differences = 0;
    var transposed = false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] == b[i]) continue;
      differences++;
      if (differences > 2) return false;
      if (differences == 2) {
        transposed =
            a[i - 1] == b[i] &&
            a[i] == b[i - 1] &&
            a.substring(i + 1) == b.substring(i + 1);
      }
    }
    return differences == 1 || (differences == 2 && transposed);
  }
  final longer = a.length > b.length ? a : b;
  final shorter = a.length > b.length ? b : a;
  for (var i = 0; i < longer.length; i++) {
    if (longer.substring(0, i) + longer.substring(i + 1) == shorter) {
      return true;
    }
  }
  return false;
}

/// The rest of the file, once the connection is settled either way.
GeneratorConfig _build(
  Map<Object?, Object?> map,
  MssqlConnectionConfig connection,
  String basePath,
  List<String> warnings, {
  bool connectionConfigured = true,
}) {
  // Refused rather than translated: the old key has fewer values than
  // decimal_mode and the default has changed.
  if (map.containsKey('decimal_as_double')) {
    throw const FormatException(
      'decimal_as_double has been replaced by decimal_mode: exact | text | '
      'double. exact is the new default and keeps DECIMAL and MONEY exact; '
      'double is the old decimal_as_double: true.',
    );
  }
  // Check remaining keys after the decimal_as_double migration message.
  _rejectUnknownKeys(
    map,
    _rootKeys,
    'The configuration',
    'Remove it, or correct the spelling. Ignoring it would generate code the '
        'file does not describe.',
  );
  return GeneratorConfig(
    connection: connection,
    output: p.join(basePath, (map['output'] ?? 'lib/db/generated').toString()),
    modelsOutput: p.join(
      basePath,
      (map['models_output'] ?? 'lib/db/models').toString(),
    ),
    extensionsOutput: p.join(
      basePath,
      (map['extensions_output'] ?? 'lib/db/extensions').toString(),
    ),
    databaseClass: (map['database_class'] ?? 'AppDatabase').toString(),
    queriesInput: p.join(
      basePath,
      (map['queries_input'] ?? 'lib/db/queries').toString(),
    ),
    snapshotPath: p.join(
      basePath,
      (map['snapshot'] ?? 'tool/mssql_schema.json').toString(),
    ),
    schemas: _stringList(map['schemas'], const <String>['dbo']).toSet(),
    scaffold: _bool(map['scaffold'], 'scaffold') ?? true,
    includeViews: _bool(map['include_views'], 'include_views') ?? true,
    include: _stringList(map['include'], const <String>['*']),
    exclude: _stringList(map['exclude'], const <String>['sysdiagrams']),
    decimalMode: _decimalMode(map['decimal_mode']),
    json: _bool(map['json'], 'json') ?? false,
    classNames: _stringMap(map['class_names']),
    fieldNames: _stringMap(map['field_names']),
    queryMethods: _stringMap(map['query_methods']),
    readOnlyColumns: _stringList(map['readonly_columns'], const <String>[]),
    hiddenColumns: _stringList(map['hidden_columns'], const <String>[]),
    conventions: _conventions(map['conventions']),
    softDeleteColumns: _nullableStringMap(
      map['soft_delete_columns'],
      'soft_delete_columns',
    ),
    hierarchyParents: _nullableStringMap(
      map['hierarchy_parents'],
      'hierarchy_parents',
    ),
    timestampColumns: _timestampColumnsMap(map['timestamps']),
    relationNames: _stringMap(map['relation_names']),
    excludedRelations: _stringList(map['exclude_relations'], const <String>[]),
    declaredRelations: _declaredRelations(map['declared_relations']),
    projections: _projections(map['projections']),
    enumColumns: _enumColumns(map['enum_columns']),
    converters: _converters(map['converters']),
    connectionConfigured: connectionConfigured,
    warnings: warnings,
  );
}

/// Reads one connection value, which may be `env:NAME` rather than the value.
String _resolveSecret(
  String key,
  String value,
  Map<String, String> environment,
  List<String> warnings, {
  bool secret = false,
}) {
  if (!value.startsWith('env:')) {
    if (secret) {
      warnings.add(
        'connection.$key is written in the configuration file rather than '
        'read from the environment. Use "env:NAME" so the secret stays out '
        'of the repository.',
      );
    }
    return value;
  }
  final name = value.substring(4);
  final fromEnvironment = environment[name];
  if (fromEnvironment == null || fromEnvironment.isEmpty) {
    throw MissingSecretError(
      'connection.$key reads the environment variable $name, which is not '
      'set. Export it, or write the value in the configuration.',
    );
  }
  return fromEnvironment;
}

MssqlConnectionConfig _offlineConnection(Map<Object?, Object?> map) =>
    MssqlConnectionConfig(
      host: 'offline',
      database: 'offline',
      username: 'offline',
      password: '',
      decimalMode: _decimalMode(map['decimal_mode']),
    );

/// Reads `decimal_mode: exact | text | double`.
///
/// The old `decimal_as_double: true|false` is refused rather than translated:
/// it had two values where there are now three, and the default has moved, so
/// a silent translation would generate different code than the file says.
MssqlDecimalMode _decimalMode(Object? value) {
  if (value == null) return MssqlDecimalMode.exact;
  final text = value.toString().trim();
  return switch (text) {
    'exact' => MssqlDecimalMode.exact,
    'text' => MssqlDecimalMode.text,
    'double' || 'doublePrecision' => MssqlDecimalMode.doublePrecision,
    _ => throw FormatException(
      'decimal_mode must be exact, text or double',
      text,
    ),
  };
}

/// A boolean from YAML, refusing anything that is not one.
///
/// Treating every other string as false makes `scaffold: ture` turn
/// scaffolding off silently, which changes what gets generated.
bool? _bool(Object? value, [String? key]) => switch (value) {
  null => null,
  final bool b => b,
  final String s => switch (s.trim().toLowerCase()) {
    'true' || 'yes' || 'on' || '1' => true,
    'false' || 'no' || 'off' || '0' => false,
    _ => throw ConfigError(
      '${key ?? 'The value'} is "$s", which is not true or false.',
    ),
  },
  _ => throw ConfigError(
    '${key ?? 'The value'} is ${value.runtimeType}, which is not true or '
    'false.',
  ),
};

List<String> _stringList(Object? value, List<String> fallback) {
  if (value == null) return fallback;
  if (value is Iterable) return value.map((e) => e.toString()).toList();
  return <String>[value.toString()];
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in value.entries)
      entry.key.toString(): entry.value.toString(),
  };
}

/// A per-table map whose value may be `false` to mean "not this table".
Map<String, String?> _nullableStringMap(Object? value, String setting) {
  if (value == null) return const <String, String?>{};
  if (value is! Map) {
    throw ConfigError('$setting must be a mapping keyed by table.');
  }
  final out = <String, String?>{};
  for (final entry in value.entries) {
    final raw = entry.value;
    if (raw == false || raw == null || raw.toString() == 'none') {
      out[entry.key.toString()] = null;
      continue;
    }
    out[entry.key.toString()] = raw.toString();
  }
  return Map<String, String?>.unmodifiable(out);
}

ConventionsConfig _conventions(Object? value) {
  if (value == null) return const ConventionsConfig();
  if (value is! Map) {
    throw const ConfigError('conventions must be a mapping.');
  }
  String? read(String key, String fallback) {
    if (!value.containsKey(key)) return fallback;
    final raw = value[key];
    if (raw == false || raw == null || raw.toString() == 'none') return null;
    return raw.toString();
  }

  return ConventionsConfig(
    softDelete: read('soft_delete', 'deleted_at'),
    createdAt: read('created_at', 'created_at'),
    updatedAt: read('updated_at', 'updated_at'),
  );
}

Map<String, TimestampColumnsConfig> _timestampColumnsMap(Object? value) {
  if (value == null) return const <String, TimestampColumnsConfig>{};
  if (value is! Map) {
    throw const ConfigError('timestamps must be a mapping keyed by table.');
  }
  final result = <String, TimestampColumnsConfig>{};
  for (final entry in value.entries) {
    final columns = entry.value;
    if (columns is! Map) {
      throw ConfigError(
        'timestamps.${entry.key} must contain created and/or updated.',
      );
    }
    final created = columns['created']?.toString();
    final updated = columns['updated']?.toString();
    if (created == null && updated == null) {
      throw ConfigError(
        'timestamps.${entry.key} must name created and/or updated.',
      );
    }
    result[entry.key.toString()] = TimestampColumnsConfig(
      createdColumn: created,
      updatedColumn: updated,
    );
  }
  return Map<String, TimestampColumnsConfig>.unmodifiable(result);
}

/// A generated DTO projection: root table, fields, optional aliases.
class ProjectionConfig {
  const ProjectionConfig({
    required this.name,
    required this.table,
    required this.fields,
  });

  final String name;
  final String table;
  final List<ProjectionFieldConfig> fields;
}

class ProjectionFieldConfig {
  const ProjectionFieldConfig({
    required this.column,
    this.alias,
    this.path,
    this.nonNull = false,
  });

  /// Dart or SQL column name on the root table.
  final String column;

  /// Result alias; defaults to [column]'s Dart name.
  final String? alias;

  /// Related path such as `customer.name`. Not generated until joins exist.
  final String? path;

  /// Runtime NULL is an error naming this projection.
  final bool nonNull;
}

List<ProjectionConfig> _projections(Object? value) {
  if (value == null) return const <ProjectionConfig>[];
  if (value is! Map) {
    throw const ConfigError('projections must be a mapping keyed by DTO name.');
  }
  final out = <ProjectionConfig>[];
  for (final entry in value.entries) {
    final body = entry.value;
    if (body is! Map) {
      throw ConfigError('projections.${entry.key} must be a mapping.');
    }
    final table = body['table']?.toString();
    if (table == null || table.isEmpty) {
      throw ConfigError('projections.${entry.key} needs table:.');
    }
    final fields = _projectionFields(
      body['fields'],
      'projections.${entry.key}.fields',
    );
    out.add(
      ProjectionConfig(
        name: entry.key.toString(),
        table: table,
        fields: fields,
      ),
    );
  }
  return List<ProjectionConfig>.unmodifiable(out);
}

List<ProjectionFieldConfig> _projectionFields(Object? value, String setting) {
  if (value is! Iterable) {
    throw ConfigError('$setting must be a list of columns.');
  }
  final out = <ProjectionFieldConfig>[];
  for (final item in value) {
    if (item is String) {
      out.add(ProjectionFieldConfig(column: item));
      continue;
    }
    if (item is Map) {
      final column = (item['column'] ?? item['name'])?.toString();
      final path = item['path']?.toString();
      if ((column == null || column.isEmpty) &&
          (path == null || path.isEmpty)) {
        throw ConfigError('$setting entries need column: or path:.');
      }
      out.add(
        ProjectionFieldConfig(
          column: column ?? path!.split('.').last,
          alias: item['alias']?.toString(),
          path: path,
          nonNull: _bool(item['non_null'], 'non_null') ?? false,
        ),
      );
      continue;
    }
    throw ConfigError('$setting entries must be a name or a mapping.');
  }
  return List<ProjectionFieldConfig>.unmodifiable(out);
}

/// An explicit relation YAML could not derive from foreign keys.
///
/// belongsToMany, *Through and morph* have no FK that names them. Guessing
/// a pivot from "two FKs" misfires on tables like OrderLines. This is the
/// only way those shapes are generated.
class DeclaredRelationConfig {
  const DeclaredRelationConfig({
    required this.owner,
    required this.name,
    required this.kind,
    required this.target,
    required this.localColumns,
    required this.foreignColumns,
    this.through,
    this.nearColumns = const <String>[],
    this.farColumns = const <String>[],
    this.typeColumn,
    this.idColumn,
    this.typeValue,
    this.unknown = 'error',
    this.targets = const <String, String>{},
  });

  final String owner;
  final String name;
  final String kind;
  final String target;
  final List<String> localColumns;
  final List<String> foreignColumns;
  final String? through;
  final List<String> nearColumns;
  final List<String> farColumns;
  final String? typeColumn;
  final String? idColumn;
  final String? typeValue;
  final String unknown;
  final Map<String, String> targets;
}

List<DeclaredRelationConfig> _declaredRelations(Object? value) {
  if (value == null) return const <DeclaredRelationConfig>[];
  if (value is! Map) {
    throw const ConfigError(
      'declared_relations must be a mapping keyed by schema.Table.name.',
    );
  }
  final out = <DeclaredRelationConfig>[];
  for (final entry in value.entries) {
    final key = entry.key.toString();
    final spec = entry.value;
    if (spec is! Map) {
      throw ConfigError('declared_relations.$key must be a mapping.');
    }
    final dot = key.lastIndexOf('.');
    if (dot <= 0) {
      throw ConfigError(
        'declared_relations key "$key" must be schema.Table.relationName.',
      );
    }
    final owner = key.substring(0, dot);
    final name = key.substring(dot + 1);
    if (name == mssqlTruncatedKeyName) {
      throw ConfigError(
        'declared_relations.$key uses the reserved relation name '
        '"$mssqlTruncatedKeyName".',
      );
    }
    final kind = spec['kind']?.toString();
    if (kind == null) {
      throw ConfigError('declared_relations.$key needs kind:.');
    }
    final target = spec['target']?.toString();
    if (target == null) {
      throw ConfigError('declared_relations.$key needs target:.');
    }
    out.add(
      DeclaredRelationConfig(
        owner: owner,
        name: name,
        kind: kind,
        target: target,
        localColumns: _stringList(spec['local'], const <String>[]),
        foreignColumns: _stringList(spec['foreign'], const <String>[]),
        through: spec['through']?.toString(),
        nearColumns: _stringList(spec['near'], const <String>[]),
        farColumns: _stringList(spec['far'], const <String>[]),
        typeColumn: spec['type_column']?.toString(),
        idColumn: spec['id_column']?.toString(),
        typeValue: spec['type_value']?.toString(),
        unknown: spec['unknown']?.toString() ?? 'error',
        targets: _stringMap(spec['targets']),
      ),
    );
  }
  return List<DeclaredRelationConfig>.unmodifiable(out);
}

/// Reserved include-metadata name; not a legal generated relation.
const String mssqlTruncatedKeyName = '__mssql_truncated';

/// How an unmapped SQL enum/string value is handled.
enum EnumUnknownPolicy { error, member, wrap }

/// An explicit column→enum mapping. String columns are never inferred.
class EnumColumnConfig {
  const EnumColumnConfig({
    required this.dartType,
    required this.unknown,
    this.unknownMember,
    this.importUri,
  });

  final String dartType;
  final EnumUnknownPolicy unknown;
  final String? unknownMember;
  final String? importUri;
}

/// An explicit column converter. The class lives in application code.
class ConverterColumnConfig {
  const ConverterColumnConfig({
    required this.dartType,
    required this.converter,
    this.importUri,
  });

  final String dartType;
  final String converter;
  final String? importUri;
}

Map<String, EnumColumnConfig> _enumColumns(Object? value) {
  if (value == null) return const <String, EnumColumnConfig>{};
  if (value is! Map) {
    throw const ConfigError(
      'enum_columns must be a mapping keyed by schema.Table.Column.',
    );
  }
  final out = <String, EnumColumnConfig>{};
  for (final entry in value.entries) {
    final key = entry.key.toString();
    final spec = entry.value;
    if (spec is! Map) {
      throw ConfigError('enum_columns.$key must be a mapping.');
    }
    final dart = spec['dart']?.toString();
    if (dart == null || dart.isEmpty) {
      throw ConfigError('enum_columns.$key needs dart: OrderStatus.');
    }
    final unknownRaw = (spec['unknown'] ?? 'error').toString();
    final unknown = switch (unknownRaw) {
      'error' => EnumUnknownPolicy.error,
      'member' => EnumUnknownPolicy.member,
      'wrap' => EnumUnknownPolicy.wrap,
      _ => throw ConfigError(
        'enum_columns.$key unknown: must be error, member or wrap.',
      ),
    };
    final member = spec['unknown_member']?.toString();
    if (unknown != EnumUnknownPolicy.error &&
        (member == null || member.isEmpty)) {
      throw ConfigError(
        'enum_columns.$key with unknown: $unknownRaw needs unknown_member:.',
      );
    }
    out[key] = EnumColumnConfig(
      dartType: dart,
      unknown: unknown,
      unknownMember: member,
      importUri: spec['import']?.toString(),
    );
  }
  return Map<String, EnumColumnConfig>.unmodifiable(out);
}

Map<String, ConverterColumnConfig> _converters(Object? value) {
  if (value == null) return const <String, ConverterColumnConfig>{};
  if (value is! Map) {
    throw const ConfigError(
      'converters must be a mapping keyed by schema.Table.Column.',
    );
  }
  final out = <String, ConverterColumnConfig>{};
  for (final entry in value.entries) {
    final key = entry.key.toString();
    final spec = entry.value;
    if (spec is! Map) {
      throw ConfigError('converters.$key must be a mapping.');
    }
    final dart = spec['dart']?.toString();
    final converter = spec['converter']?.toString();
    if (dart == null || converter == null) {
      throw ConfigError(
        'converters.$key needs dart: and converter: class names.',
      );
    }
    out[key] = ConverterColumnConfig(
      dartType: dart,
      converter: converter,
      importUri: spec['import']?.toString(),
    );
  }
  return Map<String, ConverterColumnConfig>.unmodifiable(out);
}
