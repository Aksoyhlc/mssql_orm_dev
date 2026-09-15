import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

const String _configRelative = 'tool/mssql_orm.yaml';

const String _configTemplate = r'''
# mssql_orm_dev — see doc/GENERATION.md
connection:
  from: env:MSSQL_CONNECTION_STRING
output: lib/db/generated
extensions_output: lib/db/extensions
models_output: lib/db/models
snapshot: tool/mssql_schema.json
queries_input: lib/db/queries
database_class: AppDatabase
decimal_mode: exact
schemas: [dbo]
''';

const String _exampleSql = r'''
-- name: exampleScalar
-- returns: scalar
-- describe: manual
-- column: Value int not null
SELECT 1 AS Value;
''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'config',
      abbr: 'c',
      defaultsTo: _configRelative,
      help: 'Where to write the configuration file.',
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
      'Creates a minimal mssql_orm.yaml, ignore entries, and query folder.\n',
    );
    stdout.writeln(parser.usage);
    return;
  }

  final configPath = options.option('config')!;
  final created = <String>[];
  final kept = <String>[];

  final configFile = File(configPath);
  if (configFile.existsSync()) {
    kept.add(configPath);
  } else {
    configFile.parent.createSync(recursive: true);
    configFile.writeAsStringSync(_configTemplate);
    created.add(configPath);
  }

  for (final dir in <String>[
    'lib/db/generated',
    'lib/db/models',
    'lib/db/extensions',
    'lib/db/queries',
    'tool',
  ]) {
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
      created.add('$dir/');
    }
  }

  final example = File(p.join('lib/db/queries', 'example.sql'));
  if (!example.existsSync()) {
    example.writeAsStringSync(_exampleSql);
    created.add(example.path);
  } else {
    kept.add(example.path);
  }

  final gitignore = File('.gitignore');
  const ignoreLines = <String>[
    '.mssql_orm_staging/',
    '**/.mssql_orm_staging/',
    '.mssql_orm_backup/',
    '**/.mssql_orm_backup/',
    '.mssql_orm_journal.json',
    '**/.mssql_orm_journal.json',
  ];
  if (gitignore.existsSync()) {
    final existing = gitignore.readAsStringSync();
    final missing = <String>[
      for (final line in ignoreLines)
        if (!existing.contains(line)) line,
    ];
    if (missing.isNotEmpty) {
      final buffer = StringBuffer(existing);
      if (!existing.endsWith('\n')) buffer.writeln();
      buffer.writeln('# mssql_orm_dev crash-recovery artifacts');
      for (final line in missing) {
        buffer.writeln(line);
      }
      gitignore.writeAsStringSync(buffer.toString());
      created.add('.gitignore (crash-recovery entries)');
    } else {
      kept.add('.gitignore');
    }
  } else {
    gitignore.writeAsStringSync('${ignoreLines.map((l) => l).join('\n')}\n');
    created.add('.gitignore');
  }

  stdout.writeln('dart run mssql_orm_dev:init');
  if (created.isNotEmpty) {
    stdout.writeln('created:');
    for (final path in created) {
      stdout.writeln('  $path');
    }
  }
  if (kept.isNotEmpty) {
    stdout.writeln('kept (already present, not overwritten):');
    for (final path in kept) {
      stdout.writeln('  $path');
    }
  }
  stdout.writeln(
    'Next: export MSSQL_CONNECTION_STRING, then run '
    'dart run mssql_orm_dev:snapshot and '
    'dart run mssql_orm_dev:generate. If the connection explicitly '
    'uses TLS, also configure MSSQL_TLS_CA or MSSQL_TLS_SYSTEM=1.',
  );
}
