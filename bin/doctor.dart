import 'dart:io';

import 'package:args/args.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:mssql_orm_dev/src/cli_runtime.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:path/path.dart' as p;

class _Finding {
  const _Finding(this.ok, this.code, this.message, {this.fix});
  final bool ok;
  final String code;
  final String message;
  final String? fix;
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      defaultsTo: 'tool/mssql_orm.yaml',
      help: 'Path to the configuration file.',
    )
    ..addFlag(
      'connect',
      negatable: false,
      help: 'Open the database. Default is local files and config only.',
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
      'Reports SDK, native, TLS, config and generation problems.\n'
      'Does not run tests. Connection check is --connect only.\n',
    );
    stdout.writeln(parser.usage);
    return;
  }

  final findings = <_Finding>[];
  _sdk(findings);
  await _nativeAndTls(findings);

  final configPath = options.option('config')!;
  GeneratorConfig? config;
  try {
    config = GeneratorConfig.load(configPath, requireSecrets: false);
    findings.add(_Finding(true, 'config', 'Loaded $configPath.'));
  } on ConfigError catch (error) {
    findings.add(
      _Finding(
        false,
        'config',
        error.message,
        fix: 'Run dart run mssql_orm_dev:init',
      ),
    );
  }

  if (config != null) {
    _connectionConfig(findings, config);
    _generationOutput(findings, config);
    if (options.flag('connect')) {
      await _connect(findings, config);
    } else {
      findings.add(
        const _Finding(
          true,
          'connect',
          'Skipped (local doctor). Pass --connect to open the database.',
        ),
      );
    }
  }

  var failed = 0;
  for (final finding in findings) {
    final mark = finding.ok ? 'ok  ' : 'FAIL';
    stdout.writeln('$mark [${finding.code}] ${finding.message}');
    if (!finding.ok && finding.fix != null) {
      stdout.writeln('     ${finding.fix}');
    }
    if (!finding.ok) failed++;
  }
  stdout.writeln(
    failed == 0
        ? 'doctor: ${findings.length} check(s) passed.'
        : 'doctor: $failed problem(s).',
  );
  exit(failed == 0 ? 0 : 1);
}

void _sdk(List<_Finding> findings) {
  final version = Platform.version.split(' ').first;
  final parts = version.split('.');
  final major = int.tryParse(parts.first) ?? 0;
  final minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  final ok = major > 3 || (major == 3 && minor >= 10);
  findings.add(
    _Finding(
      ok,
      'sdk',
      'Dart $version (need >=3.10).',
      fix: ok ? null : 'Upgrade the Dart SDK to 3.10 or newer.',
    ),
  );
}

Future<void> _nativeAndTls(List<_Finding> findings) async {
  try {
    await initializeCliRuntime();
    final diagnostics = MssqlRuntime.instance.diagnostics;
    findings.add(
      _Finding(
        true,
        'native',
        'FreeTDS ${diagnostics.freeTdsVersion}; handlers at '
            '${diagnostics.handlersPath}.',
      ),
    );
    findings.add(
      _Finding(
        true,
        'native_tls',
        diagnostics.tlsAvailable
            ? 'TLS backend present (${diagnostics.certificateTrust}).'
            : 'This FreeTDS build has no TLS backend. Plaintext connections '
                  'remain available; encrypted modes require a TLS build.',
      ),
    );
  } catch (error) {
    findings.add(
      _Finding(
        false,
        'native',
        error.toString(),
        fix: 'Build mssql_native native assets, then ${cliTlsHint()}',
      ),
    );
  }
  final ca = Platform.environment['MSSQL_TLS_CA'];
  if (ca != null && ca.isNotEmpty && !File(ca).existsSync()) {
    findings.add(
      _Finding(
        false,
        'tls',
        'MSSQL_TLS_CA is $ca, which is not a file.',
        fix: 'Point MSSQL_TLS_CA at a PEM bundle.',
      ),
    );
  }
}

void _connectionConfig(List<_Finding> findings, GeneratorConfig config) {
  if (config.connectionConfigured) {
    findings.add(
      _Finding(
        true,
        'connection',
        'Connection settings resolved '
            '(${config.connection.host}/${config.connection.database}). '
            'Password is not printed.',
      ),
    );
  } else {
    findings.add(
      const _Finding(
        true,
        'connection',
        'Live credentials are not set. Offline generate/snapshot-from-disk '
            'still works. Export MSSQL_CONNECTION_STRING (or host/user/'
            'password env vars) for live commands.',
      ),
    );
  }
  if (config.connection.encryption == MssqlEncryption.off) {
    findings.add(
      const _Finding(
        true,
        'encryption',
        'connection.encryption is off (plaintext default).',
      ),
    );
  } else {
    findings.add(
      _Finding(
        true,
        'encryption',
        'connection.encryption is ${config.connection.encryption.name}. '
            '${cliTlsHint()}',
      ),
    );
  }
}

void _generationOutput(List<_Finding> findings, GeneratorConfig config) {
  final output = Directory(config.output);
  if (!output.existsSync()) {
    findings.add(
      _Finding(
        true,
        'output',
        '${config.output} does not exist yet. generate will create it.',
      ),
    );
  } else {
    findings.add(_Finding(true, 'output', '${config.output} exists.'));
  }
  final snapshot = File(config.snapshotPath);
  findings.add(
    snapshot.existsSync()
        ? _Finding(true, 'snapshot', '${config.snapshotPath} exists.')
        : _Finding(
            true,
            'snapshot',
            '${config.snapshotPath} is missing. Offline generate needs it.',
            fix: 'dart run mssql_orm_dev:snapshot',
          ),
  );
  final queries = Directory(config.queriesInput);
  findings.add(
    _Finding(
      true,
      'queries',
      queries.existsSync()
          ? '${config.queriesInput} exists.'
          : '${config.queriesInput} is missing (ok if you have no .sql files).',
    ),
  );

  var contractOk = true;
  if (output.existsSync()) {
    for (final file in output.listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      final match = RegExp(r'// API contract: (\d+)').firstMatch(text);
      if (match == null) continue;
      final version = int.parse(match.group(1)!);
      if (!MssqlApiVersion.supports(version)) {
        contractOk = false;
        findings.add(
          _Finding(
            false,
            'api',
            MssqlApiVersion.mismatchMessage(version, p.basename(file.path)),
            fix: 'dart run mssql_orm_dev:generate',
          ),
        );
      }
    }
  }
  if (contractOk) {
    findings.add(
      _Finding(true, 'api', 'Runtime API contract ${MssqlApiVersion.current}.'),
    );
  }
}

Future<void> _connect(List<_Finding> findings, GeneratorConfig config) async {
  if (!config.connectionConfigured) {
    findings.add(
      const _Finding(
        false,
        'connect',
        'Cannot --connect: live credentials are not set.',
        fix: 'Export the connection env vars named in tool/mssql_orm.yaml.',
      ),
    );
    return;
  }
  try {
    await initializeCliRuntime();
    final connection = await MssqlConnection.open(config.connection);
    try {
      await connection.ping();
    } finally {
      await connection.close();
    }
    findings.add(
      const _Finding(true, 'connect', 'Opened the database and pinged it.'),
    );
  } on MssqlException catch (error) {
    findings.add(_Finding(false, 'connect', error.message, fix: cliTlsHint()));
  } catch (error) {
    findings.add(
      _Finding(false, 'connect', error.toString(), fix: cliTlsHint()),
    );
  }
}
