import 'dart:io';

import 'package:args/args.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:mssql_orm_dev/src/cli_runtime.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/describe.dart';
import 'package:mssql_orm_dev/src/generation_plan.dart';
import 'package:mssql_orm_dev/src/generator.dart';
import 'package:mssql_orm_dev/src/naming.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:mssql_orm_dev/src/version.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      defaultsTo: 'tool/mssql_orm.yaml',
      help: 'Path to the configuration file.',
    )
    ..addFlag(
      'dry-run',
      negatable: false,
      help: 'Report what would change; write nothing.',
    )
    ..addFlag(
      'check',
      negatable: false,
      help: 'Exit non-zero if anything would change. For CI.',
    )
    ..addOption(
      'report',
      allowed: <String>['text', 'json'],
      defaultsTo: 'text',
      help: 'How to print the result. json is for a CI dashboard to read.',
    )
    ..addMultiOption(
      'only',
      help:
          'Write only these tables, as Orders or dbo.Orders. Related '
          'generated files already on disk are updated with them. The '
          'barrel, the stale sweep and a missing related file are left '
          'alone.',
      valueHelp: 'table,table',
    )
    ..addFlag(
      'snapshot',
      negatable: false,
      help:
          'Generate from the schema snapshot. Needs no database password. '
          'Custom SQL still needs a matching queries cache or '
          '-- describe: manual.',
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
    stdout.writeln('Generates Dart from a live SQL Server schema.\n');
    stdout.writeln(parser.usage);
    return;
  }

  final checking = options.flag('check');
  final dryRun = options.flag('dry-run') || checking;
  final asJson = options.option('report') == 'json';
  final only = options.multiOption('only');
  try {
    final config = GeneratorConfig.load(
      options.option('config')!,
      requireSecrets: false,
    );
    final fromSnapshot =
        options.flag('snapshot') || !config.connectionConfigured;
    List<MssqlTableSchema>? tables;
    MssqlConnection? connection;
    if (fromSnapshot) {
      final file = File(config.snapshotPath);
      if (!file.existsSync()) {
        stderr.writeln(
          'No snapshot at ${config.snapshotPath}. Run '
          'dart run mssql_orm_dev:snapshot once, or export the '
          'connection env vars for a live generate.',
        );
        exit(66);
      }
      final snapshot = MssqlSchemaSnapshot.fromJsonText(
        file.readAsStringSync(),
        origin: config.snapshotPath,
      );
      if (!MssqlApiVersion.supports(snapshot.apiVersion)) {
        stderr.writeln(
          MssqlApiVersion.mismatchMessage(
            snapshot.apiVersion,
            config.snapshotPath,
          ),
        );
        exit(65);
      }
      tables = snapshot.tables;
    } else {
      await initializeCliRuntime();
      connection = await MssqlConnection.open(config.connection);
    }
    final GenerationResult result;
    try {
      result = await Generator(
        config,
        version: generatorVersion,
        dryRun: dryRun,
        only: only,
      ).run(connection: connection, tables: tables);
    } finally {
      await connection?.close();
    }

    for (final warning in result.warnings) {
      stderr.writeln('warning: $warning');
    }

    final diffs = <String, String>{
      for (final file in result.plan.files)
        if (file.action != GeneratedFileAction.unchanged)
          file.path: unifiedDiff(
            path: file.path,
            previous: file.action == GeneratedFileAction.create
                ? null
                : _readIfExists(file.path),
            next: file.action == GeneratedFileAction.remove ? '' : file.content,
          ),
    };

    if (asJson) {
      stdout.writeln(result.plan.toJsonText(diffs: diffs));
    }

    if (checking) {
      if (!asJson) {
        if (!result.changed) {
          stdout.writeln(
            'Up to date: ${result.unchanged.length} generated file(s) already '
            'match the schema.',
          );
        } else {
          _printActions(result.plan, diffs, dryRun: true);
        }
      }
      exit(result.changed ? 1 : 0);
    }

    if (dryRun) {
      if (!asJson) {
        _printActions(result.plan, diffs, dryRun: true);
      }
      return;
    }

    if (!asJson) {
      _printActions(result.plan, const <String, String>{}, dryRun: false);
      if (result.unchanged.isNotEmpty) {
        stdout.writeln(
          '${result.unchanged.length} generated file(s) already matched.',
        );
      }
      if (result.skippedScaffolds.isNotEmpty) {
        stdout.writeln(
          'kept ${result.skippedScaffolds.length} existing scaffold file(s) '
          'untouched.',
        );
      }
    }
  } on QueryFileError catch (error) {
    stderr.writeln(error.toString());
    exit(65);
  } on UndescribableQuery catch (error) {
    stderr.writeln(error.toString());
    exit(65);
  } on ConfigError catch (error) {
    stderr.writeln(error.message);
    exit(78);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exit(65);
  } on NameCollision catch (error) {
    stderr.writeln(error.toString());
    exit(65);
  } on MssqlException catch (error) {
    stderr.writeln('SQL Server: ${error.message}');
    exit(69);
  }
}

String? _readIfExists(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

void _printActions(
  GenerationPlan plan,
  Map<String, String> diffs, {
  required bool dryRun,
}) {
  var unchanged = 0;
  for (final file in plan.files) {
    switch (file.action) {
      case GeneratedFileAction.create:
        stdout.writeln(
          '${dryRun ? 'would create ' : 'wrote     '} ${file.path}',
        );
      case GeneratedFileAction.replace:
        stdout.writeln(
          '${dryRun ? 'would rewrite' : 'wrote     '} ${file.path}',
        );
      case GeneratedFileAction.remove:
        stdout.writeln(
          '${dryRun ? 'would delete ' : 'deleted   '} ${file.path}',
        );
      case GeneratedFileAction.unchanged:
        unchanged++;
    }
  }
  if (dryRun && unchanged > 0) {
    stdout.writeln('unchanged    $unchanged file(s)');
  }
  if (!dryRun) return;
  for (final file in plan.files) {
    final diff = diffs[file.path];
    if (diff == null || diff.isEmpty) continue;
    if (file.action == GeneratedFileAction.unchanged) continue;
    stdout.writeln(diff);
  }
}
