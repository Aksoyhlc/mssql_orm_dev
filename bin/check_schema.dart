import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:mssql_orm_dev/src/cli_runtime.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/schema_drift.dart';

/// Answers "is the generated code still valid against this database?".
///
/// Reads the schema snapshot when the project keeps one and compares the whole
/// shape against the live database; falls back to the per-file fingerprints in
/// the generated headers when it does not.
///
/// The generator's own `--check` answers a different question — "is the
/// generated code up to date with the schema?" — and the two are worth keeping
/// apart. This one needs no write access and touches no files, so it can run
/// as a read-only CI gate wherever the database is reachable.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      defaultsTo: 'tool/mssql_orm.yaml',
      help: 'Path to the configuration file.',
    )
    ..addFlag(
      'strict',
      negatable: false,
      help: 'Exit non-zero for benign differences too.',
    )
    ..addOption(
      'report',
      allowed: <String>['text', 'json'],
      defaultsTo: 'text',
      help: 'How to print the report. json is for a CI dashboard to read.',
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
    stdout.writeln(
      'Reports how generated code differs from the live database.\n',
    );
    stdout.writeln(parser.usage);
    return;
  }

  try {
    final config = GeneratorConfig.load(options.option('config')!);
    await initializeCliRuntime();
    final connection = await MssqlConnection.open(config.connection);
    final MssqlSchemaReport report;
    try {
      // The snapshot is the better answer when there is one: it describes the
      // whole shape the code was generated from, so a difference can name the
      // column and say why it matters. The fingerprint check is what is left
      // when there is no snapshot, and it can only say that something moved.
      report =
          await checkSchemaAgainstSnapshot(connection, config) ??
          await checkGeneratedSchema(connection, config);
    } finally {
      // exit() never returns, so calling it inside the try would leave the
      // connection to be dropped rather than closed. The server sees a clean
      // disconnect this way.
      await connection.close();
    }
    final strict = options.flag('strict');
    final failed = strict ? !report.isClean : report.hasBreakingChanges;
    if (options.option('report') == 'json') {
      stdout.writeln(_json(report, strict: strict, failed: failed));
    } else {
      stdout.write(report.describe());
    }
    exit(failed ? 1 : 0);
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

/// The report as one JSON object, for a dashboard rather than a person.
///
/// The map literal is the contract: something downstream reads these keys, so
/// they are written out here rather than derived from a `toJson` on a runtime
/// class, where a rename would quietly break a pipeline.
String _json(
  MssqlSchemaReport report, {
  required bool strict,
  required bool failed,
}) => const JsonEncoder.withIndent('  ').convert(<String, Object?>{
  'clean': report.isClean,
  'strict': strict,
  'failed': failed,
  'breaking': report.breaking.length,
  'differences': <Map<String, Object?>>[
    for (final difference in report.differences)
      <String, Object?>{
        'table': difference.table,
        'column': difference.column,
        'kind': difference.kind.name,
        'severity': difference.severity.name,
        'expected': difference.expected,
        'actual': difference.actual,
        'remedy': difference.remedy,
      },
  ],
});
