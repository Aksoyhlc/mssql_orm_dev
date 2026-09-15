import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

bool get liveEnabled => Platform.environment['MSSQL_NATIVE_LIVE'] == '1';
String? get liveSkip =>
    liveEnabled ? null : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server.';

const String schema = 'orm_e2e';

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
  'MSSQL_E2E_HOST': liveConfig.host,
  'MSSQL_E2E_PORT': '${liveConfig.port}',
  'MSSQL_E2E_DB': liveConfig.database,
  'MSSQL_E2E_USER': liveConfig.username,
  'MSSQL_E2E_PASSWORD': liveConfig.password,
  'MSSQL_TLS_INSECURE': '1',
};

const List<String> fixture = <String>[
  "IF OBJECT_ID(N'[$schema].[Orders]', N'U') IS NOT NULL DROP TABLE [$schema].[Orders];",
  "IF OBJECT_ID(N'[$schema].[Customers]', N'U') IS NOT NULL DROP TABLE [$schema].[Customers];",
  "IF SCHEMA_ID(N'$schema') IS NULL EXEC(N'CREATE SCHEMA [$schema]');",
  '''
CREATE TABLE [$schema].[Customers] (
  [Id]         INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_e2e_Customers] PRIMARY KEY,
  [Name]       NVARCHAR(100) NOT NULL,
  [Email]      NVARCHAR(200) NULL,
  [created_at] DATETIME2(3) NULL,
  [updated_at] DATETIME2(3) NULL,
  [deleted_at] DATETIME2(3) NULL
);''',
  '''
CREATE TABLE [$schema].[Orders] (
  [Id]         INT IDENTITY(1,1) NOT NULL CONSTRAINT [PK_e2e_Orders] PRIMARY KEY,
  [CustomerId] INT NOT NULL CONSTRAINT [FK_e2e_Orders_Customers]
                 REFERENCES [$schema].[Customers]([Id]),
  [Code]       VARCHAR(20) NOT NULL,
  [Total]      DECIMAL(18,4) NOT NULL,
  [IsOpen]     BIT NOT NULL
);''',
];

const String applicationSource = r'''
import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';

import 'package:e2e_app/db/generated/generated.dart';

Future<void> main() async {
  await MssqlRuntime.instance.initialize();
  final connection = await MssqlConnection.open(
    MssqlConnectionConfig(
      host: Platform.environment['MSSQL_E2E_HOST'] ?? '127.0.0.1',
      port: int.parse(Platform.environment['MSSQL_E2E_PORT'] ?? '1433'),
      database:
          Platform.environment['MSSQL_E2E_DB'] ?? 'mssql_native_test',
      username: Platform.environment['MSSQL_E2E_USER'] ?? 'sa',
      password: Platform.environment['MSSQL_E2E_PASSWORD'] ?? '',
      decimalMode: MssqlDecimalMode.text,
      encryption: MssqlEncryption.off,
    ),
  );

  final db = AppDatabase.borrow(connection);
  final customers = CustomersRepository(connection);
  final orders = OrdersRepository(connection);

  final ali = await customers.insert(
    const CustomersRow(id: 0, name: 'Ali Yilmaz', email: 'ali@example.com'),
  );
  final veli = await customers.insert(
    const CustomersRow(id: 0, name: 'Veli Demir'),
  );
  print('STAMPED ${ali.createdAt != null}');

  await orders.insertAll(<OrdersRow>[
    OrdersRow(id: 0, customerId: ali.id, code: 'A-1', total: '150.0000', isOpen: true),
    OrdersRow(id: 0, customerId: ali.id, code: 'A-2', total: '75.5000', isOpen: true),
    OrdersRow(id: 0, customerId: veli.id, code: 'V-1', total: '20.0000', isOpen: false),
  ]);

  final found = await customers.findWhere(
    whereAny(<String>['Name', 'Email'], (c) => c.contains('ali')),
  );
  print('SEARCH ${found.length}');

  final page = await customers.page(
    offset: 0,
    rows: 10,
    orderBy: <MssqlOrder>[Customers.id.asc()],
    include: <MssqlRelation<CustomersRow, Object?>>[CustomersRel.orders],
  );
  print('EAGER ${page.rows.map((c) => c.orders.length).join(",")}');

  final open = await MssqlQuery.fromParts(<String>['SCHEMA', 'Orders'])
      .where(Orders.code.startsWith('A-'))
      .where(Orders.isOpen.eq(true))
      .count(connection);
  print('FILTER $open');

  final totals = await db.reports.openTotalsByCustomer(minimum: '50');
  print('TYPED ${totals.map((t) => "${t.customerName}=${t.toplam}").join(",")}');

  await customers.delete(veli.id);
  print('SOFT ${await customers.count()} '
      '${await CustomersRepository(connection).withTrashed().count()}');

  await connection.close();
}
''';

const String querySource = r'''
-- name: openTotalsByCustomer
-- param: minimum decimal
SELECT c.Name AS CustomerName, SUM(o.Total) AS Toplam, COUNT(*) AS Adet
FROM SCHEMA.Orders AS o
JOIN SCHEMA.Customers AS c ON c.Id = o.CustomerId
WHERE o.IsOpen = 1 AND c.deleted_at IS NULL
GROUP BY c.Name
HAVING SUM(o.Total) >= @minimum;
''';

late Directory project;
late String devPath;
late String ormPath;
late String driverPath;

Future<ProcessResult> runCli(List<String> arguments) => Process.run(
  'dart',
  <String>['run', 'mssql_orm_dev:generate', ...arguments],
  workingDirectory: project.path,
  environment: cliEnvironment,
);

void write(String relative, String contents) {
  final file = File(p.join(project.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void main() {
  group('the whole loop, against a server', () {
    late MssqlConnection connection;

    setUpAll(() async {
      if (!liveEnabled) return;
      await MssqlRuntime.instance.initialize();
      connection = await MssqlConnection.open(liveConfig);
      for (final statement in fixture) {
        await connection.execute(statement);
      }

      final here = Directory.current.path;
      devPath = here;
      ormPath = p.normalize(p.join(here, '..', 'mssql_orm'));
      driverPath = p.normalize(p.join(here, '..', 'mssql_native'));

      project = Directory.systemTemp.createTempSync('orm_e2e_');
      write('pubspec.yaml', '''
name: e2e_app
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
    path: $devPath
  lints: ^5.0.0
dependency_overrides:
  mssql_native:
    path: $driverPath
  mssql_orm:
    path: $ormPath
''');
      write(
        'analysis_options.yaml',
        'include: package:lints/recommended.yaml\n',
      );
      write('tool/mssql_orm.yaml', '''
connection:
  host: env:MSSQL_E2E_HOST
  port: env:MSSQL_E2E_PORT
  database: env:MSSQL_E2E_DB
  user: env:MSSQL_E2E_USER
  password: env:MSSQL_E2E_PASSWORD

output: lib/db/generated
models_output: lib/db/models
queries_input: lib/db/queries
schemas: [$schema]
decimal_mode: text
''');
      write(
        'lib/db/queries/open_totals.sql',
        querySource.replaceAll('SCHEMA', schema),
      );

      final get = await Process.run('dart', <String>[
        'pub',
        'get',
      ], workingDirectory: project.path);
      if (get.exitCode != 0) {
        fail('dart pub get failed:\n${get.stdout}\n${get.stderr}');
      }
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      if (project.existsSync()) project.deleteSync(recursive: true);
      for (final statement in fixture.take(2)) {
        await connection.execute(statement);
      }
      await connection.close();
    });

    test(
      'the CLI writes where the configuration says, not beside it',
      () async {
        final result = await runCli(const <String>[]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(
          File(
            p.join(project.path, 'lib', 'db', 'generated', 'customers.g.dart'),
          ).existsSync(),
          isTrue,
        );
        expect(
          Directory(p.join(project.path, 'tool', 'lib')).existsSync(),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveSkip,
    );

    test('typed SQL is generated in the same run', () async {
      expect(
        File(
          p.join(project.path, 'lib', 'db', 'generated', 'queries.g.dart'),
        ).existsSync(),
        isTrue,
      );
    }, skip: liveSkip);

    test('the conventions found the columns without being configured', () {
      final source = File(
        p.join(project.path, 'lib', 'db', 'generated', 'customers.g.dart'),
      ).readAsStringSync();
      expect(source, contains("MssqlSoftDelete(column: 'deleted_at')"));
      expect(source, contains("createdColumn: 'created_at'"));
      expect(source, contains('CustomersRel'));
    }, skip: liveSkip);

    test(
      '--check passes when nothing changed',
      () async {
        final result = await runCli(const <String>['--check']);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('Up to date'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveSkip,
    );

    test(
      'a second run leaves the generated queries alone',
      () async {
        final before = File(
          p.join(project.path, 'lib', 'db', 'generated', 'queries.g.dart'),
        ).readAsStringSync();
        final result = await runCli(const <String>[]);
        expect(result.exitCode, 0);
        expect(result.stdout.toString(), isNot(contains('deleted')));
        expect(
          File(
            p.join(project.path, 'lib', 'db', 'generated', 'queries.g.dart'),
          ).readAsStringSync(),
          before,
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveSkip,
    );

    test(
      '--check fails once the schema moves ahead of the code',
      () async {
        await connection.execute(
          'ALTER TABLE [$schema].[Customers] ADD [Phone] NVARCHAR(30) NULL;',
        );
        final result = await runCli(const <String>['--check']);
        expect(result.exitCode, 1);
        expect(result.stdout.toString(), contains('would rewrite'));

        await connection.execute(
          'ALTER TABLE [$schema].[Customers] DROP COLUMN [Phone];',
        );
        expect((await runCli(const <String>[])).exitCode, 0);
      },
      timeout: const Timeout(Duration(minutes: 4)),
      skip: liveSkip,
    );

    test(
      'an application compiles against it with one import per table',
      () async {
        write('bin/app.dart', applicationSource.replaceAll('SCHEMA', schema));
        final scaffold = File(
          p.join(project.path, 'lib', 'db', 'models', 'customers.dart'),
        );
        expect(
          scaffold.readAsStringSync(),
          contains("export '../generated/customers.g.dart';"),
        );

        final analyse = await Process.run('dart', <String>[
          'analyze',
        ], workingDirectory: project.path);
        expect(
          analyse.exitCode,
          0,
          reason: 'dart analyze reported:\n${analyse.stdout}',
        );
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveSkip,
    );

    test(
      'and running it does what the schema says it should',
      () async {
        final run = await Process.run(
          'dart',
          <String>['run', 'bin/app.dart'],
          workingDirectory: project.path,
          environment: cliEnvironment,
        );
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final out = run.stdout.toString();

        expect(out, contains('STAMPED true'));
        expect(out, contains('SEARCH 1'));
        expect(out, contains('EAGER 2,1'));
        expect(out, contains('FILTER 2'));
        expect(out, contains('TYPED Ali Yilmaz=225.5000'));
        expect(out, contains('SOFT 1 2'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveSkip,
    );

    test(
      'the barrel is one import for every table, and reaches the models',
      () async {
        final barrel = File(
          p.join(project.path, 'lib', 'db', 'generated', 'generated.dart'),
        ).readAsStringSync();
        expect(barrel, contains("export '../models/customers.dart';"));
        expect(barrel, contains("export '../models/orders.dart';"));
        final tableExports = barrel
            .split('\n')
            .where((line) => line.startsWith('export '))
            .where((line) => !line.startsWith("export 'database.g.dart'"))
            .where((line) => !line.startsWith("export 'queries.g.dart'"))
            .where((line) => !line.startsWith("export 'procedures.g.dart'"));
        expect(tableExports, everyElement(isNot(contains('.g.dart'))));
        expect(barrel, contains("export 'database.g.dart';"));
      },
      skip: liveSkip,
    );
  });
}

