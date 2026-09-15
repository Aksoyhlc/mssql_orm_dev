import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'atomic_writer.dart';
import 'config.dart';
import 'describe.dart';
import 'emit/procedure_emitter.dart';
import 'emitter.dart';
import 'generation_banner.dart';
import 'generation_plan.dart';
import 'manifest.dart';
import 'naming.dart';
import 'query_emitter.dart';
import 'query_runner.dart';
import 'query_shape_cache.dart';

/// What one run did, or would have done.
class GenerationResult {
  const GenerationResult({
    required this.plan,
    required this.written,
    required this.unchanged,
    required this.scaffolded,
    required this.deleted,
    required this.skippedScaffolds,
    required this.warnings,
  });

  final GenerationPlan plan;

  /// Generated files whose content differs from what is on disk.
  final List<String> written;

  /// Generated files already identical to what would be written.
  final List<String> unchanged;

  /// Scaffold files created for the first time.
  final List<String> scaffolded;

  /// Stale generated files removed.
  final List<String> deleted;

  /// Scaffold files left alone because they already exist.
  final List<String> skippedScaffolds;

  final List<String> warnings;

  bool get changed => plan.changed;
}

/// Reads a live schema and writes Dart for it.
class Generator {
  Generator(
    this.config, {
    required this.version,
    this.dryRun = false,
    this.only = const <String>[],
  });

  final GeneratorConfig config;
  final String version;
  final bool dryRun;

  /// Write only these tables, named as `Orders` or `dbo.Orders`.
  /// The whole schema is still read for relation derivation.
  final List<String> only;

  bool get _isPartial => only.isNotEmpty;

  final DartFormatter _formatter = DartFormatter(
    languageVersion: Version(3, 10, 0),
  );

  /// Live generation: one connection for catalog and custom-SQL describe.
  Future<GenerationResult> run({
    MssqlConnection? connection,
    List<MssqlTableSchema>? tables,
  }) async {
    final opened =
        connection ??
        (tables == null ? await MssqlConnection.open(config.connection) : null);
    final owned = connection == null && opened != null;
    try {
      final resolved =
          tables ??
          await MssqlSchemaReader(opened!).readTables(
            schemas: config.schemas,
            includeViews: config.includeViews,
            include: config.include,
            exclude: config.exclude,
          );
      if (resolved.isEmpty) {
        throw ConfigError(
          'No table matched schemas ${config.schemas.join(', ')} with '
          'include ${config.include.join(', ')}. Check the filters before '
          'anything is written.',
        );
      }
      String? queriesSource;
      String? proceduresSource;
      List<DescribedQuery>? describedQueries;
      final includeQueries = !_isPartial;
      if (includeQueries) {
        final described = await describeQueryFiles(opened, config);
        describedQueries = described;
        final reserved = <String>{
          for (final table in resolved) fieldName(table.name),
        };
        final reports = <DescribedQuery>[
          for (final query in described)
            if (query.definition.procedure == null) query,
        ];
        final procedures = <DescribedQuery>[
          for (final query in described)
            if (query.definition.procedure != null) query,
        ];
        if (reports.isNotEmpty) {
          queriesSource = _formatter.format(
            emitQueries(
              reports,
              config,
              version: version,
              reservedNames: reserved,
            ),
          );
        }
        if (procedures.isNotEmpty) {
          proceduresSource = _formatter.format(
            emitProcedures(
              procedures,
              config,
              version: version,
              reservedNames: reserved,
            ),
          );
        }
      }
      return _finish(
        resolved,
        queriesSource: queriesSource,
        proceduresSource: proceduresSource,
        includeQueries: includeQueries,
        describedQueries: describedQueries,
      );
    } finally {
      if (owned) await opened.close();
    }
  }

  /// Split out so the emitter can be tested against in-memory schemas.
  GenerationResult emitFor(List<MssqlTableSchema> tables) => _finish(tables);

  /// The formatted plan, before any disk write.
  GenerationPlan planFor(
    List<MssqlTableSchema> tables, {
    String? queriesSource,
    String? proceduresSource,
    bool includeQueries = false,
    List<DescribedQuery>? describedQueries,
  }) => _plan(
    tables,
    queriesSource: queriesSource,
    proceduresSource: proceduresSource,
    includeQueries: includeQueries,
    describedQueries: describedQueries,
  );

  GenerationResult _finish(
    List<MssqlTableSchema> tables, {
    String? queriesSource,
    String? proceduresSource,
    bool includeQueries = false,
    List<DescribedQuery>? describedQueries,
  }) {
    final plan = _plan(
      tables,
      queriesSource: queriesSource,
      proceduresSource: proceduresSource,
      includeQueries: includeQueries,
      describedQueries: describedQueries,
    );
    if (!dryRun) {
      AtomicWriter(
        outputDirectory: config.output,
        scaffoldDirectories: <String>[
          config.modelsOutput,
          config.extensionsOutput,
        ],
      ).publish(plan);
    }
    return _resultFrom(plan);
  }

  GenerationPlan _plan(
    List<MssqlTableSchema> tables, {
    String? queriesSource,
    String? proceduresSource,
    bool includeQueries = false,
    List<DescribedQuery>? describedQueries,
  }) {
    // Stable order: two runs against one schema must produce byte-identical
    // output, or every regeneration buries the real change in noise.
    final ordered = <MssqlTableSchema>[...tables]
      ..sort((a, b) {
        final bySchema = a.schema.compareTo(b.schema);
        return bySchema != 0 ? bySchema : a.name.compareTo(b.name);
      });

    // Case-insensitive settings, file names and lookups cannot represent two
    // objects whose names differ only by case, even when the collation allows
    // both. Generation therefore rejects the collision.
    final byFoldedName = <String, String>{};
    final ambiguous = <String>[];
    for (final table in ordered) {
      final folded = table.qualifiedName.toLowerCase();
      final first = byFoldedName[folded];
      if (first != null && first != table.qualifiedName) {
        ambiguous.add('$first / ${table.qualifiedName}');
      } else {
        byFoldedName[folded] = table.qualifiedName;
      }
    }
    if (ambiguous.isNotEmpty) {
      throw ConfigError(
        'This database has objects whose names differ only in case '
        '(${ambiguous.join('; ')}). Generating both would mean folding them '
        'together. Exclude one of each pair, or give them distinct class '
        'names under `class_names:`. Nothing was written.',
      );
    }

    final plans = <TablePlan>[];
    final classNames = <String, String>{};
    final relationWarnings = <String>[];
    for (final table in ordered) {
      final plan = TablePlan.of(
        table,
        config,
        world: ordered,
        relationWarnings: relationWarnings,
      );
      plans.add(plan);
      classNames[table.qualifiedName] = plan.rowClass;
    }
    checkDistinct('the generated output', classNames);
    _checkOverridesResolve(ordered);
    for (final name in only) {
      if (plans.any(
        (plan) => KeyedSetting.matches(name, plan.table.qualifiedName),
      )) {
        continue;
      }
      throw ConfigError(
        '--only names "$name", which is not a table the filters selected. '
        'Nothing was written.',
      );
    }

    final closure = _closure(plans);
    final warnings = <String>[...config.warnings, ...relationWarnings];
    final skipped = <String>[];
    final proposed = <String, String>{};
    final scaffoldHashes = <String, String>{};

    for (final tablePlan in plans) {
      final generatedPath = p.join(
        config.output,
        '${tablePlan.fileName}.g.dart',
      );
      final selected = _isPartial
          ? closure.contains(tablePlan.table.qualifiedName.toLowerCase())
          : true;
      if (!selected) continue;

      final named = !_isPartial || _namedInOnly(tablePlan);
      if (_isPartial && !named && !File(generatedPath).existsSync()) {
        warnings.add(
          '${tablePlan.table.qualifiedName} is in the dependency closure '
          'of --only (${only.join(', ')}) but ${tablePlan.fileName}.g.dart '
          'does not exist yet. Run without --only to create it.',
        );
        continue;
      }
      if (_isPartial && !named) {
        warnings.add(
          'also updating $generatedPath (relation/projection closure of '
          '${only.join(', ')})',
        );
      }
      proposed[generatedPath] = _formatter.format(
        emitGenerated(tablePlan, version: version),
      );

      if (config.scaffold) {
        final scaffoldPath = p.join(
          config.modelsOutput,
          '${tablePlan.fileName}.dart',
        );
        final scaffoldSource = _formatter.format(emitScaffold(tablePlan));
        scaffoldHashes[scaffoldPath] = sha256Hex(scaffoldSource);
        if (File(scaffoldPath).existsSync()) {
          skipped.add(scaffoldPath);
        } else if (named || !_isPartial) {
          proposed[scaffoldPath] = scaffoldSource;
        }
      }

      final extensionPath = p.join(
        config.extensionsOutput,
        '${tablePlan.fileName}_scopes.dart',
      );
      final extensionSource = _formatter.format(emitScopeScaffold(tablePlan));
      scaffoldHashes[extensionPath] = sha256Hex(extensionSource);
      if (File(extensionPath).existsSync()) {
        skipped.add(extensionPath);
      } else if (named || !_isPartial) {
        proposed[extensionPath] = extensionSource;
      }
    }

    if (!_isPartial) {
      proposed[p.join(config.output, 'generated.dart')] = _formatter.format(
        _emitBarrel(
          plans,
          hasQueries: includeQueries && queriesSource != null,
          hasProcedures: includeQueries && proceduresSource != null,
        ),
      );
      proposed[p.join(config.output, 'database.g.dart')] = _formatter.format(
        emitDatabase(
          plans,
          databaseClass: config.databaseClass,
          version: version,
          includeReports: queriesSource != null,
          includeProcedures: proceduresSource != null,
        ),
      );
    }

    if (includeQueries) {
      final queriesPath = p.join(config.output, 'queries.g.dart');
      if (queriesSource != null) {
        proposed[queriesPath] = queriesSource;
      }
      final proceduresPath = p.join(config.output, 'procedures.g.dart');
      if (proceduresSource != null) {
        proposed[proceduresPath] = proceduresSource;
      }
      if (describedQueries != null && describedQueries.isNotEmpty) {
        proposed[QueryShapeCache.pathFor(
          config,
        )] = QueryShapeCache(<CachedQueryShape>[
          for (final query in describedQueries)
            CachedQueryShape.fromDescribed(query),
        ]).toJsonText();
      }
    }

    final previous = GenerationManifest.read(config.output);
    final previousOwned =
        previous?.files.toSet() ??
        GenerationManifest.bootstrapOwned(config.output);
    if (previous != null) {
      for (final entry in scaffoldHashes.entries) {
        final was = previous.scaffolds[entry.key];
        if (was != null && was != entry.value) {
          warnings.add(
            '${entry.key} still has the previous constructor/extension '
            'contract. Regeneration does not overwrite it; review the file '
            'against the new generated row and query types, then keep or '
            'rewrite the subclass by hand.',
          );
        }
      }
    }

    final ownedBasenames = <String>{};
    for (final path in proposed.keys) {
      if (_isGeneratedOutput(path)) {
        ownedBasenames.add(p.basename(path));
      }
    }
    if (_isPartial) {
      ownedBasenames.addAll(previousOwned);
    } else if (!includeQueries) {
      ownedBasenames.addAll(previousOwned.intersection(kOtherPassBasenames));
    }

    final files = <PlannedFile>[];
    for (final entry in proposed.entries) {
      files.add(_compare(entry.key, entry.value));
    }

    if (!_isPartial) {
      for (final name in previousOwned) {
        if (ownedBasenames.contains(name)) continue;
        if (name == GenerationManifest.fileName) continue;
        if (!includeQueries && kOtherPassBasenames.contains(name)) {
          continue;
        }
        final path = p.join(config.output, name);
        if (!File(path).existsSync()) continue;
        files.add(PlannedFile(path, '', GeneratedFileAction.remove));
      }
      // A leftover queries.g.dart with no remaining .sql files is stale
      // even if an older generator never listed it in the manifest.
      // Leaving it would make --check green next to dead typed SQL.
      if (includeQueries && queriesSource == null) {
        final queriesPath = p.join(config.output, 'queries.g.dart');
        if (File(queriesPath).existsSync() &&
            !files.any((file) => file.path == queriesPath)) {
          files.add(PlannedFile(queriesPath, '', GeneratedFileAction.remove));
        }
      }
      if (includeQueries && proceduresSource == null) {
        final proceduresPath = p.join(config.output, 'procedures.g.dart');
        if (File(proceduresPath).existsSync() &&
            !files.any((file) => file.path == proceduresPath)) {
          files.add(
            PlannedFile(proceduresPath, '', GeneratedFileAction.remove),
          );
        }
      }
    }

    final digestSources = <String, String>{
      for (final file in files)
        if (file.action != GeneratedFileAction.remove &&
            _isGeneratedOutput(file.path))
          p.basename(file.path): file.content,
    };
    final generationId = generationIdFor(digestSources);
    final mergedScaffolds = <String, String>{
      ...?previous?.scaffolds,
      ...scaffoldHashes,
    };
    final ownedList = (ownedBasenames.toList()..sort());
    final manifest = GenerationManifest(
      generationId: generationId,
      files: ownedList,
      scaffolds: mergedScaffolds,
    );
    files.add(
      _compare(
        GenerationManifest.pathFor(config.output),
        manifest.toJsonText(),
      ),
    );

    files.sort((a, b) => a.path.compareTo(b.path));
    return GenerationPlan(
      generationId: generationId,
      files: files,
      warnings: warnings,
      skippedScaffolds: skipped,
    );
  }

  GenerationResult _resultFrom(GenerationPlan plan) {
    final written = <String>[];
    final unchanged = <String>[];
    final scaffolded = <String>[];
    final deleted = <String>[];
    for (final file in plan.files) {
      if (p.basename(file.path) == GenerationManifest.fileName) continue;
      switch (file.action) {
        case GeneratedFileAction.create:
          if (_isScaffoldPath(file.path)) {
            scaffolded.add(file.path);
          } else {
            written.add(file.path);
          }
        case GeneratedFileAction.replace:
          written.add(file.path);
        case GeneratedFileAction.remove:
          deleted.add(file.path);
        case GeneratedFileAction.unchanged:
          if (!_isScaffoldPath(file.path)) {
            unchanged.add(file.path);
          }
      }
    }
    return GenerationResult(
      plan: plan,
      written: written,
      unchanged: unchanged,
      scaffolded: scaffolded,
      deleted: deleted,
      skippedScaffolds: plan.skippedScaffolds,
      warnings: plan.warnings,
    );
  }

  bool _isGeneratedOutput(String path) {
    final directory = p.normalize(config.output);
    return p.normalize(p.dirname(path)) == directory;
  }

  bool _isScaffoldPath(String path) {
    final models = p.normalize(config.modelsOutput);
    final extensions = p.normalize(config.extensionsOutput);
    final dir = p.normalize(p.dirname(path));
    return dir == models || dir == extensions;
  }

  PlannedFile _compare(String path, String content) {
    final file = File(path);
    if (!file.existsSync()) {
      return PlannedFile(path, content, GeneratedFileAction.create);
    }
    final existing = file.readAsStringSync();
    if (existing == content) {
      return PlannedFile(path, content, GeneratedFileAction.unchanged);
    }
    return PlannedFile(path, content, GeneratedFileAction.replace);
  }

  bool _namedInOnly(TablePlan plan) =>
      only.any((name) => KeyedSetting.matches(name, plan.table.qualifiedName));

  /// Tables named by `--only`, plus tables that carry a relation to them.
  Set<String> _closure(List<TablePlan> plans) {
    if (!_isPartial) {
      return <String>{
        for (final plan in plans) plan.table.qualifiedName.toLowerCase(),
      };
    }
    final byQualified = <String, TablePlan>{
      for (final plan in plans) plan.table.qualifiedName.toLowerCase(): plan,
    };
    final selected = <String>{};
    void add(String qualified) {
      final key = qualified.toLowerCase();
      if (!selected.add(key)) return;
      final plan = byQualified[key];
      if (plan == null) return;
      for (final relation in plan.relations) {
        add(relation.target);
        final through = relation.through?.bindingTable;
        if (through != null) add(through);
      }
    }

    for (final name in only) {
      for (final plan in plans) {
        if (KeyedSetting.matches(name, plan.table.qualifiedName)) {
          add(plan.table.qualifiedName);
        }
      }
    }
    // Tables that point at a selected table even if the selected side
    // does not list them first — hasMany lives on the parent.
    for (final plan in plans) {
      for (final relation in plan.relations) {
        if (selected.contains(relation.target.toLowerCase())) {
          add(plan.table.qualifiedName);
        }
      }
    }
    return selected;
  }

  /// Checks that every override key resolves to an actual table or column.
  void _checkOverridesResolve(List<MssqlTableSchema> tables) {
    // Both spellings of each, folded: a configuration key may name a table as
    // `dbo.Orders` or as `Orders`, in whatever case, and all of them are the
    // one table as far as SQL Server is concerned.
    final tableNames = <String>{
      for (final t in tables) ...<String>[
        t.qualifiedName.toLowerCase(),
        t.name.toLowerCase(),
      ],
    };
    final columnNames = <String>{
      for (final t in tables)
        for (final c in t.columns) ...<String>[
          '${t.qualifiedName}.${c.name}'.toLowerCase(),
          '${t.name}.${c.name}'.toLowerCase(),
        ],
    };
    final bareColumns = <String>{
      for (final t in tables)
        for (final c in t.columns) c.name.toLowerCase(),
    };

    for (final key in config.classNames.keys) {
      if (!tableNames.contains(key.toLowerCase())) {
        throw ConfigError(
          'class_names names "$key", which is not a table '
          'the filters selected.',
        );
      }
    }
    for (final key in config.fieldNames.keys) {
      if (!columnNames.contains(key.toLowerCase())) {
        throw ConfigError(
          'field_names names "$key", which is not a column '
          'the filters selected.',
        );
      }
    }
    for (final key in config.queryMethods.keys) {
      if (!columnNames.contains(key.toLowerCase())) {
        throw ConfigError(
          'query_methods names "$key", which is not a column '
          'the filters selected.',
        );
      }
    }
    for (final entry in config.softDeleteColumns.entries) {
      // A null value opts the table out, so there is no column to check —
      // only that the table itself was selected.
      final column = entry.value;
      if (column == null) {
        _requireConfiguredTable('soft_delete_columns', entry.key, tables);
        continue;
      }
      _requireConfiguredColumn(
        'soft_delete_columns',
        entry.key,
        column,
        tables,
        mustBeNullable: true,
        mustStoreServerClock: true,
      );
    }
    for (final entry in config.timestampColumns.entries) {
      final stamps = entry.value;
      if (stamps.createdColumn != null) {
        _requireConfiguredColumn(
          'timestamps.${entry.key}.created',
          entry.key,
          stamps.createdColumn!,
          tables,
          mustStoreServerClock: true,
        );
      }
      if (stamps.updatedColumn != null) {
        _requireConfiguredColumn(
          'timestamps.${entry.key}.updated',
          entry.key,
          stamps.updatedColumn!,
          tables,
          mustStoreServerClock: true,
        );
      }
      if (stamps.createdColumn != null &&
          stamps.createdColumn!.toLowerCase() ==
              stamps.updatedColumn?.toLowerCase()) {
        throw ConfigError(
          'timestamps.${entry.key} must use different created and updated columns.',
        );
      }
      final softDelete = config.softDeleteColumns[entry.key]?.toLowerCase();
      if (softDelete != null &&
          (softDelete == stamps.createdColumn?.toLowerCase() ||
              softDelete == stamps.updatedColumn?.toLowerCase())) {
        throw ConfigError(
          '${entry.key} cannot use one column for soft deletes and timestamps.',
        );
      }
    }
    for (final entry in <MapEntry<String, List<String>>>[
      MapEntry('readonly_columns', config.readOnlyColumns),
      MapEntry('hidden_columns', config.hiddenColumns),
    ]) {
      for (final pattern in entry.value) {
        final matched = pattern.startsWith('*.')
            ? bareColumns.contains(pattern.substring(2).toLowerCase())
            : columnNames.contains(pattern.toLowerCase());
        if (!matched) {
          throw ConfigError(
            '${entry.key} names "$pattern", which matches no column the '
            'filters selected.',
          );
        }
      }
    }
    for (final entry in config.enumColumns.entries) {
      final matched = columnNames.any(
        (name) => KeyedSetting.matches(entry.key, name),
      );
      if (!matched) {
        throw ConfigError(
          'enum_columns names "${entry.key}", which is not a column the '
          'filters selected. String columns are not turned into enums '
          'unless named here.',
        );
      }
    }
    for (final entry in config.converters.entries) {
      final matched = columnNames.any(
        (name) => KeyedSetting.matches(entry.key, name),
      );
      if (!matched) {
        throw ConfigError(
          'converters names "${entry.key}", which is not a column the '
          'filters selected.',
        );
      }
    }
    for (final projection in config.projections) {
      if (!tableNames.contains(projection.table.toLowerCase()) &&
          !tables.any(
            (t) => KeyedSetting.matches(projection.table, t.qualifiedName),
          )) {
        throw ConfigError(
          'projections.${projection.name} names table "${projection.table}", '
          'which is not a table the filters selected.',
        );
      }
    }
  }

  /// The table [tableName] names, or a [ConfigError] saying it was not
  /// selected.
  MssqlTableSchema _requireConfiguredTable(
    String setting,
    String tableName,
    List<MssqlTableSchema> tables,
  ) {
    for (final candidate in tables) {
      if (KeyedSetting.matches(tableName, candidate.qualifiedName)) {
        return candidate;
      }
    }
    throw ConfigError(
      '$setting names "$tableName", which is not a table the filters selected.',
    );
  }

  void _requireConfiguredColumn(
    String setting,
    String tableName,
    String columnName,
    List<MssqlTableSchema> tables, {
    bool mustBeNullable = false,
    bool mustStoreServerClock = false,
  }) {
    final table = _requireConfiguredTable(setting, tableName, tables);
    MssqlColumnSchema? column;
    for (final candidate in table.columns) {
      if (candidate.name.toLowerCase() == columnName.toLowerCase()) {
        column = candidate;
        break;
      }
    }
    if (column == null) {
      throw ConfigError(
        '$setting names "$columnName", which is not a column of $tableName.',
      );
    }
    final configuredReadOnly = _matchesConfiguredColumn(
      config.readOnlyColumns,
      tableName,
      column.name,
    );
    if (column.isServerGenerated || configuredReadOnly) {
      throw ConfigError('$setting must name a writable column.');
    }
    if (mustBeNullable && !column.nullable) {
      throw ConfigError('$setting must name a nullable column.');
    }
    if (mustStoreServerClock && !_storesServerClock(column.type)) {
      throw ConfigError('$setting must name a date/time column.');
    }
  }

  bool _storesServerClock(MssqlType type) => switch (type) {
    MssqlType.date ||
    MssqlType.time ||
    MssqlType.smallDateTime ||
    MssqlType.dateTime ||
    MssqlType.dateTime2 ||
    MssqlType.dateTimeOffset => true,
    _ => false,
  };

  /// One import for the whole database, so an application does not write ten.
  String _emitBarrel(
    List<TablePlan> plans, {
    required bool hasQueries,
    required bool hasProcedures,
  }) {
    final out = StringBuffer();
    writeGenerationBanner(out, version: version);
    out.writeln('//');
    out.writeln(
      config.scaffold
          ? '// One import for every table: the models, each of which\n'
                '// re-exports the generated half it is built on.'
          : '// One import for every table.',
    );
    out.writeln();
    final prefix = config.scaffold
        ? '${p.relative(config.modelsOutput, from: config.output)}/'
        : '';
    for (final plan in plans) {
      final target = config.scaffold
          ? '$prefix${plan.fileName}.dart'
          : '${plan.fileName}.g.dart';
      out.writeln("export '${p.split(target).join('/')}';");
    }
    out.writeln();
    out.writeln('// The database class and the custom-query mixins it uses.');
    out.writeln("export 'database.g.dart';");
    if (hasQueries) out.writeln("export 'queries.g.dart';");
    if (hasProcedures) out.writeln("export 'procedures.g.dart';");
    return out.toString();
  }
}

bool _matchesConfiguredColumn(
  List<String> patterns,
  String qualifiedTable,
  String column,
) => patterns.any(
  (pattern) =>
      pattern == '$qualifiedTable.$column' ||
      (pattern.startsWith('*.') && pattern.substring(2) == column),
);
