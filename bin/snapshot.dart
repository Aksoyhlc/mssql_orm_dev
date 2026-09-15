import 'dart:io';

import 'package:args/args.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/cli_runtime.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:path/path.dart' as p;

/// Writes the database's shape to a file, so that generation can run offline.
///
/// This is the one command that needs a live database and produces something
/// the others can use without one. What it needs from the server is catalog
/// access — `sys.objects`, `sys.columns`, `sys.indexes` and friends — and
/// nothing more: it never reads a row of table data.
///
/// The file it writes holds no connection string, no user name and no
/// password. It is meant for version control.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      defaultsTo: 'tool/mssql_orm.yaml',
      help: 'Path to the configuration file.',
    )
    ..addOption(
      'out',
      abbr: 'o',
      help: 'Where to write the snapshot. Defaults to the configured path.',
    )
    ..addFlag(
      'check',
      negatable: false,
      help:
          'Compare the live database against the snapshot on disk and exit '
          'non-zero when it has drifted. Writes nothing.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (options.flag('help')) {
    stdout.writeln('Captures the database schema to a file.\n');
    stdout.writeln(parser.usage);
    return;
  }

  try {
    final config = GeneratorConfig.load(options.option('config')!);
    final path = options.option('out') ?? config.snapshotPath;
    await initializeCliRuntime();
    final connection = await MssqlConnection.open(config.connection);
    final MssqlSchemaSnapshot snapshot;
    try {
      snapshot = await MssqlSchemaSnapshot.capture(
        connection,
        schemas: config.schemas,
        includeViews: config.includeViews,
        include: config.include,
        exclude: config.exclude,
      );
    } finally {
      // exit() never returns, so closing has to happen before any exit path.
      await connection.close();
    }

    final ambiguous = snapshot.ambiguousNames;
    if (ambiguous.isNotEmpty) {
      stderr.writeln(
        'This database has names that differ only in case '
        '(${ambiguous.join('; ')}). Generated Dart would fold them together, '
        'so the snapshot was not written. Exclude one of each pair, or give '
        'them distinct class names in the configuration.',
      );
      exit(65);
    }

    if (options.flag('check')) {
      final file = File(path);
      if (!file.existsSync()) {
        stderr.writeln(
          'No snapshot at $path. Run without --check to make one.',
        );
        exit(66);
      }
      final stored = MssqlSchemaSnapshot.fromJsonText(
        file.readAsStringSync(),
        origin: path,
      );
      if (stored.checksum == snapshot.checksum) {
        stdout.writeln('$path matches the database.');
        return;
      }
      stderr.writeln(
        '$path no longer matches the database. It was captured '
        '${stored.capturedAt.toIso8601String()}. Run '
        'dart run mssql_orm_dev:snapshot to refresh it, then '
        'regenerate.',
      );
      exit(1);
    }

    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${snapshot.toJsonText()}\n');
    stdout.writeln(
      'Wrote ${p.relative(path)}: ${snapshot.tables.length} object(s), '
      'server ${snapshot.serverVersion}, compatibility level '
      '${snapshot.compatibilityLevel}.',
    );
  } on ConfigError catch (error) {
    stderr.writeln(error.message);
    exit(78);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(65);
  } on MssqlException catch (error) {
    stderr.writeln('SQL Server: ${error.message}');
    exit(69);
  }
}
