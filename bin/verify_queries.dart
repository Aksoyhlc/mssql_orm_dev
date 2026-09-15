import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/cli_runtime.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/describe.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:mssql_orm_dev/src/query_runner.dart';
import 'package:mssql_orm_dev/src/version.dart';

/// Re-describes every hand-written query and reports where SQL Server no
/// longer agrees with the generated code.
///
/// A renamed column or changed type is caught here rather than in production.
/// The check is read-only, so it belongs in CI wherever the database is
/// reachable.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c', defaultsTo: 'tool/mssql_orm.yaml')
    ..addOption(
      'report',
      allowed: <String>['text', 'json'],
      defaultsTo: 'text',
      help: 'How to print the result. json is for a CI dashboard to read.',
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
    stdout.writeln('Checks hand-written .sql files against the database.\n');
    stdout.writeln(parser.usage);
    return;
  }

  try {
    final config = GeneratorConfig.load(options.option('config')!);
    await initializeCliRuntime();
    final connection = await MssqlConnection.open(config.connection);
    final List<QueryDrift> drift;
    try {
      drift = await verifyQueries(
        connection,
        config,
        version: generatorVersion,
      );
    } finally {
      // exit() never returns, so calling it inside the try would leave the
      // connection to be dropped rather than closed.
      await connection.close();
    }
    if (options.option('report') == 'json') {
      // On stdout either way: a dashboard reads one stream, and splitting the
      // clean case from the dirty one across two would make it read neither.
      stdout.writeln(_json(drift));
      exit(drift.isEmpty ? 0 : 1);
    }
    if (drift.isEmpty) {
      stdout.writeln('Every query still matches its generated code.');
      exit(0);
    }
    for (final entry in drift) {
      stderr.writeln(entry.toString());
    }
    exit(1);
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
  } on MssqlException catch (error) {
    stderr.writeln('SQL Server: ${error.message}');
    exit(69);
  }
}

/// The result as one JSON object, for a dashboard rather than a person.
String _json(List<QueryDrift> drift) =>
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'clean': drift.isEmpty,
      'drift': <Map<String, Object?>>[
        for (final entry in drift)
          <String, Object?>{'query': entry.query, 'message': entry.message},
      ],
    });
