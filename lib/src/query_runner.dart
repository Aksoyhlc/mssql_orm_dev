import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:glob/glob.dart';
import 'package:glob/list_local_fs.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'config.dart';
import 'describe.dart';
import 'emit/procedure_emitter.dart';
import 'query_emitter.dart';
import 'query_file.dart';
import 'query_shape_cache.dart';

/// Reads every `.sql` file under [directory], sorted, so two runs agree.
List<QueryDefinition> loadQueryFiles(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) return const <QueryDefinition>[];
  final files =
      Glob('**.sql').listSync(root: directory).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return <QueryDefinition>[
    for (final file in files)
      parseQueryFile(
        p.relative(file.path, from: directory),
        file.readAsStringSync(),
      ),
  ];
}

/// Describes every query under [config.queriesInput].
Future<List<DescribedQuery>> describeQueryFiles(
  MssqlConnection? connection,
  GeneratorConfig config,
) async {
  final definitions = loadQueryFiles(config.queriesInput);
  if (definitions.isEmpty) return const <DescribedQuery>[];

  if (connection != null) {
    final describer = QueryDescriber(connection);
    final described = <DescribedQuery>[
      for (final definition in definitions)
        await describer.describe(definition),
    ];
    _checkNamesDistinct(described);
    return described;
  }

  final cache = QueryShapeCache.read(config);
  final described = <DescribedQuery>[];
  for (final definition in definitions) {
    if (definition.isManual) {
      described.add(describeManual(definition));
      continue;
    }
    final cached = cache.find(definition.sourcePath);
    if (cached == null) {
      throw ConfigError(
        '${definition.sourcePath} has no cached describe. Run generate '
        'with a database connection once, or add "-- describe: manual".',
      );
    }
    if (cached.sourceHash != definition.sourceHash) {
      throw ConfigError(
        '${definition.sourcePath} changed since it was last described. '
        'Offline generation will not reuse stale metadata. Run generate '
        'against the database, or declare "-- describe: manual".',
      );
    }
    described.add(cached.toDescribed(definition));
  }
  _checkNamesDistinct(described);
  return described;
}

/// Describes every query and writes the typed files.
Future<int> generateQueries(
  MssqlConnection connection,
  GeneratorConfig config, {
  required String version,
  bool dryRun = false,
}) async {
  final described = await describeQueryFiles(connection, config);
  if (described.isEmpty) return 0;

  if (!dryRun) {
    final reports = <DescribedQuery>[
      for (final query in described)
        if (query.definition.procedure == null) query,
    ];
    final procedures = <DescribedQuery>[
      for (final query in described)
        if (query.definition.procedure != null) query,
    ];
    Directory(config.output).createSync(recursive: true);
    final formatter = DartFormatter(languageVersion: Version(3, 10, 0));
    if (reports.isNotEmpty) {
      File(p.join(config.output, 'queries.g.dart')).writeAsStringSync(
        formatter.format(emitQueries(reports, config, version: version)),
      );
    }
    if (procedures.isNotEmpty) {
      File(p.join(config.output, 'procedures.g.dart')).writeAsStringSync(
        formatter.format(emitProcedures(procedures, config, version: version)),
      );
    }
  }
  return described.length;
}

/// One difference between a `.sql` file and the code generated from it.
class QueryDrift {
  const QueryDrift(this.query, this.message);
  final String query;
  final String message;
  @override
  String toString() => '$query: $message';
}

/// Re-describes every query and reports drift from the generated code.
Future<List<QueryDrift>> verifyQueries(
  MssqlConnection connection,
  GeneratorConfig config, {
  required String version,
}) async {
  final definitions = loadQueryFiles(config.queriesInput);
  final describer = QueryDescriber(connection);
  final drift = <QueryDrift>[];
  final described = <DescribedQuery>[];
  for (final definition in definitions) {
    final verified = await describer.verify(definition);
    described.add(verified.query);
    final mismatch = verified.drift;
    if (mismatch != null) {
      drift.add(QueryDrift(definition.name, mismatch));
    }
    final unverified = verified.unverified;
    if (unverified != null) {
      drift.add(QueryDrift(definition.name, unverified));
    }
  }
  final reports = <DescribedQuery>[
    for (final query in described)
      if (query.definition.procedure == null) query,
  ];
  final procedures = <DescribedQuery>[
    for (final query in described)
      if (query.definition.procedure != null) query,
  ];
  final formatter = DartFormatter(languageVersion: Version(3, 10, 0));
  if (reports.isNotEmpty) {
    final path = p.join(config.output, 'queries.g.dart');
    final existing = File(path);
    if (!existing.existsSync()) {
      drift.add(
        QueryDrift('(all)', 'No generated file at $path. Generate first.'),
      );
    } else {
      final fresh = formatter.format(
        emitQueries(reports, config, version: version),
      );
      if (_withoutHeader(fresh) !=
          _withoutHeader(existing.readAsStringSync())) {
        drift.add(
          QueryDrift(
            '(all)',
            'The generated queries no longer match what the server describes. '
                'Regenerate and review the diff.',
          ),
        );
      }
    }
  }
  if (procedures.isNotEmpty) {
    final path = p.join(config.output, 'procedures.g.dart');
    final existing = File(path);
    if (!existing.existsSync()) {
      drift.add(
        QueryDrift('(all)', 'No generated file at $path. Generate first.'),
      );
    } else {
      final fresh = formatter.format(
        emitProcedures(procedures, config, version: version),
      );
      if (_withoutHeader(fresh) !=
          _withoutHeader(existing.readAsStringSync())) {
        drift.add(
          QueryDrift(
            '(all)',
            'The generated procedures no longer match the declared wrappers. '
                'Regenerate and review the diff.',
          ),
        );
      }
    }
  }
  return drift;
}

/// The header carries the generator version, which changes without the queries
/// changing.
String _withoutHeader(String source) =>
    source.split('\n').where((l) => !l.startsWith('// Generator:')).join('\n');

void _checkNamesDistinct(List<DescribedQuery> queries) {
  final seen = <String, String>{};
  for (final query in queries) {
    final kind = query.definition.procedure == null ? 'report' : 'procedure';
    final name = '$kind:${query.definition.name}';
    final previous = seen[name];
    if (previous != null) {
      throw QueryFileError(
        query.definition.sourcePath,
        'The name "${query.definition.name}" is already used by $previous. '
        'Two $kind methods cannot share one name.',
      );
    }
    seen[name] = query.definition.sourcePath;
  }
}
