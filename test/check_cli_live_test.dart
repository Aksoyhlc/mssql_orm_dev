import 'dart:convert';
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool get liveEnabled => Platform.environment['MSSQL_NATIVE_LIVE'] == '1';
String? get liveSkip =>
    liveEnabled ? null : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server.';

const String schema = 'orm_cli';

MssqlConnectionConfig get liveConfig => MssqlConnectionConfig(
  host: Platform.environment['MSSQL_NATIVE_HOST'] ?? '127.0.0.1',
  port: int.parse(Platform.environment['MSSQL_NATIVE_PORT'] ?? '1433'),
  database: Platform.environment['MSSQL_NATIVE_DB'] ?? 'mssql_native_test',
  username: Platform.environment['MSSQL_NATIVE_USER'] ?? 'sa',
  password: Platform.environment['MSSQL_NATIVE_PASSWORD'] ?? 'Mssql@Native2026',
  decimalMode: MssqlDecimalMode.text,
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 30),
);

Map<String, String> get cliEnvironment => <String, String>{
  ...Platform.environment,
  'MSSQL_CLI_HOST': liveConfig.host,
  'MSSQL_CLI_PORT': '${liveConfig.port}',
  'MSSQL_CLI_DB': liveConfig.database,
  'MSSQL_CLI_USER': liveConfig.username,
  'MSSQL_CLI_PASSWORD': liveConfig.password,
  'MSSQL_TLS_INSECURE': '1',
};

const List<String> fixture = <String>[
  "IF OBJECT_ID(N'[$schema].[Products]', N'U') IS NOT NULL DROP TABLE [$schema].[Products];",
  "IF SCHEMA_ID(N'$schema') IS NULL EXEC(N'CREATE SCHEMA [$schema]');",
  '''
CREATE TABLE [$schema].[Products] (
  [Id]    INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_cli_Products] PRIMARY KEY,
  [Name]  NVARCHAR(100) NOT NULL,
  [Price] DECIMAL(18,4) NOT NULL
);''',
];

const String querySource = '''
-- name: pricedAbove
-- param: floor decimal
SELECT p.Id, p.Name, p.Price
FROM SCHEMA.Products AS p
WHERE p.Price >= @floor
ORDER BY p.Price DESC;
''';

late Directory project;

Future<ProcessResult> run(
  String executable, [
  List<String> arguments = const <String>[],
]) => Process.run(
  'dart',
  <String>['run', 'mssql_orm_dev:$executable', ...arguments],
  workingDirectory: project.path,
  environment: cliEnvironment,
);

void write(String relative, String contents) {
  final file = File(p.join(project.path, relative))
    ..parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

String outputPath(String name) =>
    p.join(project.path, 'lib', 'db', 'generated', name);

void main() {
  group('the read-only gates', () {
    late MssqlConnection connection;

    setUpAll(() async {
      if (!liveEnabled) return;
      await MssqlRuntime.instance.initialize();
      connection = await MssqlConnection.open(liveConfig);
      for (final statement in fixture) {
        await connection.execute(statement);
      }

      final here = Directory.current.path;
      final ormPath = p.normalize(p.join(here, '..', 'mssql_orm'));
      final driverPath = p.normalize(p.join(here, '..', 'mssql_native'));

      project = Directory.systemTemp.createTempSync('orm_cli_');
      write('pubspec.yaml', '''
name: cli_app
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  meta: ^1.12.0
  mssql_native:
    path: $driverPath
  mssql_orm:
    path: $ormPath
dev_dependencies:
  mssql_orm_dev:
    path: $here
dependency_overrides:
  mssql_native:
    path: $driverPath
  mssql_orm:
    path: $ormPath
''');
      write('tool/mssql_orm.yaml', '''
connection:
  host: env:MSSQL_CLI_HOST
  port: env:MSSQL_CLI_PORT
  database: env:MSSQL_CLI_DB
  user: env:MSSQL_CLI_USER
  password: env:MSSQL_CLI_PASSWORD

output: lib/db/generated
models_output: lib/db/models
queries_input: lib/db/queries
schemas: [$schema]
decimal_mode: text
''');
      write(
        'lib/db/queries/priced_above.sql',
        querySource.replaceAll('SCHEMA', schema),
      );

      final get = await Process.run('dart', <String>[
        'pub',
        'get',
      ], workingDirectory: project.path);
      if (get.exitCode != 0) {
        fail('dart pub get failed:\n${get.stdout}\n${get.stderr}');
      }

      final generated = await run('generate');
      if (generated.exitCode != 0) {
        fail('generate failed:\n${generated.stdout}\n${generated.stderr}');
      }
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      if (project.existsSync()) project.deleteSync(recursive: true);
      await connection.execute(fixture.first);
      await connection.close();
    });

    group('check_schema', () {
      test(
        'exits 0 and says so when the code matches the database',
        () async {
          final result = await run('check_schema');
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout.toString(), contains('matches the database'));
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 1 and names the table once a column is added',
        () async {
          await connection.execute(
            'ALTER TABLE [$schema].[Products] ADD [Sku] VARCHAR(20) NULL;',
          );
          try {
            final result = await run('check_schema');
            expect(result.exitCode, 1);
            expect(result.stdout.toString(), contains('$schema.Products'));
            expect(result.stdout.toString(), contains('Regenerate'));
          } finally {
            await connection.execute(
              'ALTER TABLE [$schema].[Products] DROP COLUMN [Sku];',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 0 again once the change is reverted',
        () async {
          expect((await run('check_schema')).exitCode, 0);
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'a new table is benign by default and breaking under --strict',
        () async {
          await connection.execute('''
CREATE TABLE [$schema].[Suppliers] (
  [Id] INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_cli_Suppliers] PRIMARY KEY
);''');
          try {
            final lenient = await run('check_schema');
            expect(lenient.exitCode, 0, reason: lenient.stdout.toString());
            expect(lenient.stdout.toString(), contains('Suppliers'));

            final strict = await run('check_schema', const <String>[
              '--strict',
            ]);
            expect(strict.exitCode, 1);
          } finally {
            await connection.execute('DROP TABLE [$schema].[Suppliers];');
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 78 for a configuration file that is not there',
        () async {
          final result = await run('check_schema', const <String>[
            '--config',
            'tool/absent.yaml',
          ]);
          expect(result.exitCode, 78);
          expect(result.stderr.toString(), contains('absent.yaml'));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: liveSkip,
      );

      test(
        '--help explains itself and exits 0',
        () async {
          final result = await run('check_schema', const <String>['--help']);
          expect(result.exitCode, 0);
          expect(result.stdout.toString(), contains('--strict'));
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: liveSkip,
      );

      test(
        'writes nothing',
        () async {
          final before = File(outputPath('products.g.dart')).readAsStringSync();
          await run('check_schema');
          expect(
            File(outputPath('products.g.dart')).readAsStringSync(),
            before,
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );
    });

    group('verify_queries', () {
      test(
        'exits 0 while the SQL still describes the same way',
        () async {
          final result = await run('verify_queries');
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout.toString(), contains('still matches'));
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 1 when a column the query selects becomes nullable',
        () async {
          await connection.execute(
            'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] DECIMAL(18,4) NULL;',
          );
          try {
            final result = await run('verify_queries');
            expect(result.exitCode, 1);
            expect(result.stderr.toString(), contains('Regenerate'));
          } finally {
            await connection.execute(
              'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] DECIMAL(18,4) NOT NULL;',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'is silent about a change the generated code does not encode',
        () async {
          await connection.execute(
            'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] DECIMAL(9,2) NOT NULL;',
          );
          try {
            final result = await run('verify_queries');
            expect(
              result.exitCode,
              0,
              reason: '${result.stdout}\n${result.stderr}',
            );
          } finally {
            await connection.execute(
              'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] DECIMAL(18,4) NOT NULL;',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 1 when a query is added but not generated',
        () async {
          final added = p.join(
            project.path,
            'lib',
            'db',
            'queries',
            'by_name.sql',
          );
          write('lib/db/queries/by_name.sql', '''
-- name: byName
-- param: name nvarchar
SELECT p.Id FROM $schema.Products AS p WHERE p.Name = @name;
''');
          try {
            expect((await run('verify_queries')).exitCode, 1);
          } finally {
            File(added).deleteSync();
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 65 for SQL the server refuses',
        () async {
          write('lib/db/queries/broken.sql', '''
-- name: broken
SELECT p.NoSuchColumn FROM $schema.Products AS p;
''');
          try {
            final result = await run('verify_queries');
            expect(result.exitCode, anyOf(65, 69));
            expect(result.stderr.toString(), isNotEmpty);
          } finally {
            File(
              p.join(project.path, 'lib', 'db', 'queries', 'broken.sql'),
            ).deleteSync();
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 65 for a .sql file with no name directive',
        () async {
          write('lib/db/queries/unnamed.sql', 'SELECT 1;\n');
          try {
            final result = await run('verify_queries');
            expect(result.exitCode, 65);
            expect(result.stderr.toString(), contains('unnamed.sql'));
          } finally {
            File(
              p.join(project.path, 'lib', 'db', 'queries', 'unnamed.sql'),
            ).deleteSync();
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'exits 78 for a missing configuration file',
        () async {
          final result = await run('verify_queries', const <String>[
            '--config',
            'tool/absent.yaml',
          ]);
          expect(result.exitCode, 78);
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: liveSkip,
      );

      test(
        'writes nothing',
        () async {
          final before = File(outputPath('queries.g.dart')).readAsStringSync();
          await run('verify_queries');
          expect(File(outputPath('queries.g.dart')).readAsStringSync(), before);
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );
    });

    group('--report json', () {
      Map<String, Object?> decode(ProcessResult result) =>
          jsonDecode(result.stdout.toString()) as Map<String, Object?>;

      test(
        'check_schema prints an object a dashboard can read',
        () async {
          final result = await run('check_schema', const <String>[
            '--report',
            'json',
          ]);
          expect(result.exitCode, 0);
          final report = decode(result);
          expect(report['clean'], isTrue);
          expect(report['failed'], isFalse);
          expect(report['breaking'], 0);
          expect(report['differences'], isEmpty);
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'and names the difference it found',
        () async {
          await connection.execute(
            'ALTER TABLE [$schema].[Products] ADD [Sku] VARCHAR(20) NULL;',
          );
          try {
            final result = await run('check_schema', const <String>[
              '--report',
              'json',
            ]);
            expect(result.exitCode, 1);
            final report = decode(result);
            expect(report['clean'], isFalse);
            expect(report['failed'], isTrue);
            expect(report['breaking'], 1);
            final differences = report['differences']! as List<Object?>;
            final first = differences.single! as Map<String, Object?>;
            expect(first['table'], '$schema.Products');
            expect(first['kind'], 'schemaFingerprintChanged');
            expect(first['severity'], 'breaking');
            expect(first['remedy'], contains('Regenerate'));
          } finally {
            await connection.execute(
              'ALTER TABLE [$schema].[Products] DROP COLUMN [Sku];',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'strict is reported, so the reader knows which gate ran',
        () async {
          await connection.execute(
            'CREATE TABLE [$schema].[Vendors] ([Id] INT NOT NULL '
            'CONSTRAINT [PK_cli_Vendors] PRIMARY KEY);',
          );
          try {
            final lenient = decode(
              await run('check_schema', const <String>['--report', 'json']),
            );
            expect(lenient['strict'], isFalse);
            expect(lenient['failed'], isFalse);
            expect(lenient['clean'], isFalse);

            final strict = decode(
              await run('check_schema', const <String>[
                '--strict',
                '--report',
                'json',
              ]),
            );
            expect(strict['strict'], isTrue);
            expect(strict['failed'], isTrue);
          } finally {
            await connection.execute('DROP TABLE [$schema].[Vendors];');
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'verify_queries answers on stdout whether it is clean or not',
        () async {
          final clean = decode(
            await run('verify_queries', const <String>['--report', 'json']),
          );
          expect(clean['clean'], isTrue);
          expect(clean['drift'], isEmpty);

          await connection.execute(
            'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] '
            'DECIMAL(18,4) NULL;',
          );
          try {
            final result = await run('verify_queries', const <String>[
              '--report',
              'json',
            ]);
            expect(result.exitCode, 1);
            final dirty = decode(result);
            expect(dirty['clean'], isFalse);
            expect(dirty['drift'], hasLength(1));
          } finally {
            await connection.execute(
              'ALTER TABLE [$schema].[Products] ALTER COLUMN [Price] '
              'DECIMAL(18,4) NOT NULL;',
            );
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'an unknown report format is refused',
        () async {
          final result = await run('check_schema', const <String>[
            '--report',
            'xml',
          ]);
          expect(result.exitCode, 64);
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: liveSkip,
      );
    });

    group('generate --only', () {
      test(
        'rewrites the one table and leaves the others alone',
        () async {
          final products = File(outputPath('products.g.dart'));
          final barrel = File(outputPath('generated.dart'));
          final queries = File(outputPath('queries.g.dart'));
          final barrelBefore = barrel.readAsStringSync();
          final queriesBefore = queries.readAsStringSync();
          products.writeAsStringSync('// scribbled over\n');


          final result = await run('generate', const <String>[
            '--only',
            'Products',
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          expect(products.readAsStringSync(), contains('// Source: '));

          expect(barrel.readAsStringSync(), barrelBefore);
          expect(queries.readAsStringSync(), queriesBefore);
          expect(result.stdout.toString(), isNot(contains('deleted')));
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );

      test(
        'a name that matches no table stops the run',
        () async {
          final result = await run('generate', const <String>[
            '--only',
            'Prodcuts',
          ]);
          expect(result.exitCode, isNot(0));
          expect('${result.stdout}${result.stderr}', contains('Prodcuts'));
        },
        timeout: const Timeout(Duration(minutes: 3)),
        skip: liveSkip,
      );
    });
  });
}

