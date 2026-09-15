import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:path/path.dart' as p;

import 'config.dart';

/// The identity and fingerprint recorded in the header of one generated file.
class GeneratedTableStamp {
  const GeneratedTableStamp({
    required this.qualifiedName,
    required this.fingerprint,
    required this.path,
  });

  final String qualifiedName;
  final String fingerprint;
  final String path;
}

/// Reads the `Source:` and `Schema fingerprint:` lines out of every generated
/// file under [directory].
List<GeneratedTableStamp> readGeneratedStamps(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) return const <GeneratedTableStamp>[];

  final stamps = <GeneratedTableStamp>[];
  final files =
      root
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.g.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    if (p.basename(file.path) == 'queries.g.dart') continue;
    String? source;
    String? fingerprint;
    for (final line in file.readAsLinesSync()) {
      // The header is the leading comment block; anything after it is code.
      if (!line.startsWith('//')) break;
      const sourcePrefix = '// Source: ';
      const fingerprintPrefix = '// Schema fingerprint: ';
      if (line.startsWith(sourcePrefix)) {
        source = line.substring(sourcePrefix.length).trim();
      } else if (line.startsWith(fingerprintPrefix)) {
        fingerprint = line.substring(fingerprintPrefix.length).trim();
      }
    }
    if (source == null || fingerprint == null) continue;
    stamps.add(
      GeneratedTableStamp(
        qualifiedName: source,
        fingerprint: fingerprint,
        path: file.path,
      ),
    );
  }
  return stamps;
}

/// Compares the schema snapshot on disk against the live database.
/// Returns null when no snapshot exists, so callers can use the generated-file
/// fingerprint check instead.
Future<MssqlSchemaReport?> checkSchemaAgainstSnapshot(
  MssqlConnection connection,
  GeneratorConfig config,
) async {
  final file = File(config.snapshotPath);
  if (!file.existsSync()) return null;
  final snapshot = MssqlSchemaSnapshot.fromJsonText(
    file.readAsStringSync(),
    origin: config.snapshotPath,
  );
  return MssqlSchemaCheck.verifySnapshot(
    connection,
    snapshot,
    includeViews: config.includeViews,
  );
}

/// Compares generated-file fingerprints against the live database when no
/// schema snapshot is available. A fingerprint reports that a table changed;
/// the snapshot check can describe the individual schema differences.
Future<MssqlSchemaReport> checkGeneratedSchema(
  MssqlConnection connection,
  GeneratorConfig config,
) async {
  final tables = await MssqlSchemaReader(connection).readTables(
    schemas: config.schemas,
    includeViews: config.includeViews,
    include: config.include,
    exclude: config.exclude,
  );
  final live = <String, MssqlTableSchema>{
    for (final table in tables) table.qualifiedName.toLowerCase(): table,
  };

  final stamps = readGeneratedStamps(config.output);
  final differences = <MssqlSchemaDifference>[];
  final covered = <String>{};

  for (final stamp in stamps) {
    final key = stamp.qualifiedName.toLowerCase();
    covered.add(key);
    final table = live[key];
    if (table == null) {
      differences.add(
        MssqlSchemaDifference(
          table: stamp.qualifiedName,
          kind: MssqlDifferenceKind.tableMissing,
          severity: MssqlDifferenceSeverity.breaking,
          expected: 'a table',
          actual: 'nothing',
          remedy:
              'The table was dropped, renamed, or excluded by the '
              'configuration; regenerate.',
        ),
      );
      continue;
    }
    final current = fingerprintOf(table);
    if (current != stamp.fingerprint) {
      differences.add(
        MssqlSchemaDifference(
          table: stamp.qualifiedName,
          kind: MssqlDifferenceKind.schemaFingerprintChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: stamp.fingerprint,
          actual: current,
          remedy:
              'The table changed since ${p.basename(stamp.path)} was '
              'generated. Regenerate and read the diff.',
        ),
      );
    }
  }

  for (final table in tables) {
    if (covered.contains(table.qualifiedName.toLowerCase())) continue;
    differences.add(
      MssqlSchemaDifference(
        table: table.qualifiedName,
        kind: MssqlDifferenceKind.tableUngenerated,
        // An ungenerated table appearing does not break anything that exists.
        severity: MssqlDifferenceSeverity.benign,
        expected: 'a generated file',
        actual: 'nothing',
        remedy: 'Regenerate to pick the table up, or exclude it.',
      ),
    );
  }

  return MssqlSchemaReport(differences);
}
