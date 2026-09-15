import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/describe.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:test/test.dart';

bool get liveEnabled => Platform.environment['MSSQL_NATIVE_LIVE'] == '1';
String? get liveSkip =>
    liveEnabled ? null : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server.';

const String schema = 'orm_query_fixture';

MssqlConnectionConfig get config => MssqlConnectionConfig(
  host: Platform.environment['MSSQL_NATIVE_HOST'] ?? '127.0.0.1',
  port: int.parse(Platform.environment['MSSQL_NATIVE_PORT'] ?? '1433'),
  database: Platform.environment['MSSQL_NATIVE_DB'] ?? 'mssql_native_test',
  username: Platform.environment['MSSQL_NATIVE_USER'] ?? 'sa',
  password: Platform.environment['MSSQL_NATIVE_PASSWORD'] ?? 'Mssql@Native2026',
  decimalMode: MssqlDecimalMode.text,
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 30),
);

void main() {
  group('the describer, against a server', () {
    late MssqlConnection connection;
    late QueryDescriber describer;

    setUpAll(() async {
      if (!liveEnabled) return;
      await MssqlRuntime.instance.initialize();
      connection = await MssqlConnection.open(config);
      for (final statement in <String>[
        "IF OBJECT_ID(N'[$schema].[Lines]', N'U') IS NOT NULL DROP TABLE [$schema].[Lines];",
        "IF OBJECT_ID(N'[$schema].[Orders]', N'U') IS NOT NULL DROP TABLE [$schema].[Orders];",
        "IF OBJECT_ID(N'[$schema].[sp_Report]', N'P') IS NOT NULL DROP PROCEDURE [$schema].[sp_Report];",
        "IF SCHEMA_ID(N'$schema') IS NULL EXEC(N'CREATE SCHEMA [$schema]');",
        '''
CREATE TABLE [$schema].[Orders] (
  [Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  [Code] VARCHAR(20) NOT NULL,
  [Total] DECIMAL(18,4) NOT NULL,
  [Note] NVARCHAR(100) NULL
);
''',
        '''
CREATE TABLE [$schema].[Lines] (
  [Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
  [OrderId] INT NOT NULL,
  [Qty] INT NOT NULL
);
''',
        '''
CREATE PROCEDURE [$schema].[sp_Report] @yil INT AS
BEGIN
  SET NOCOUNT ON;
  SELECT [Id], [Code] FROM [$schema].[Orders] WHERE YEAR(GETDATE()) = @yil;
END;
''',
      ]) {
        await connection.execute(statement);
      }
      describer = QueryDescriber(connection);
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      await connection.close();
    });

    Future<DescribedQuery> describe(String contents) =>
        describer.describe(parseQueryFile('q.sql', contents));

    test('a simple SELECT reports its columns, in order', () async {
      final result = await describe('''
-- name: simple
SELECT [Id], [Code], [Total] FROM [$schema].[Orders];
''');
      expect(result.columns.map((c) => c.name), <String>[
        'Id',
        'Code',
        'Total',
      ]);
      expect(result.columns.first.sqlTypeName, 'int');
      expect(result.columns[1].sqlTypeName, 'varchar');
      expect(result.columns.last.sqlTypeName, 'decimal');
    }, skip: liveSkip);

    test('a type keeps its precision and scale', () async {
      final result = await describe(
        '-- name: q\nSELECT [Total] FROM [$schema].[Orders];',
      );
      expect(result.columns.single.precision, 18);
      expect(result.columns.single.scale, 4);
    }, skip: liveSkip);

    test('nullability follows the column', () async {
      final result = await describe('''
-- name: q
SELECT [Code], [Note] FROM [$schema].[Orders];
''');
      expect(result.columns.first.nullable, isFalse);
      expect(result.columns.last.nullable, isTrue);
    }, skip: liveSkip);

    test('an outer join makes the right-hand columns nullable', () async {
      final result = await describe('''
-- name: q
SELECT o.[Id], l.[Qty]
FROM [$schema].[Orders] AS o
LEFT JOIN [$schema].[Lines] AS l ON l.[OrderId] = o.[Id];
''');
      expect(result.columns.first.nullable, isFalse);
      expect(result.columns.last.nullable, isTrue);
    }, skip: liveSkip);

    test('an aggregate over no rows is reported nullable', () async {
      final result = await describe('''
-- name: q
SELECT SUM([Total]) AS [Toplam] FROM [$schema].[Orders];
''');
      expect(result.columns.single.name, 'Toplam');
      expect(result.columns.single.nullable, isTrue);
    }, skip: liveSkip);

    test('a parameter type is inferred without being declared', () async {
      final result = await describe('''
-- name: q
SELECT [Id] FROM [$schema].[Orders] WHERE [Code] = @code;
''');
      expect(result.parameters.single.name, 'code');
      expect(result.parameters.single.sqlTypeName, 'varchar');
    }, skip: liveSkip);

    test(
      'a parameter that decides a result column is described, not refused',
      () async {
        final result = await describe('''
-- name: q
-- param: code varchar(20)
SELECT @code AS [Code], [Id] FROM [$schema].[Orders] WHERE [Code] = @code;
''');
        expect(result.columns.map((c) => c.name), <String>['Code', 'Id']);
        expect(result.columns.first.sqlTypeName, 'varchar');
        expect(result.parameters.single.name, 'code');
      },
      skip: liveSkip,
    );

    test(
      'an inferred parameter decides a result column just as well',
      () async {
        final result = await describe('''
-- name: q
SELECT [Id] + @n AS [Shifted] FROM [$schema].[Orders];
''');
        expect(result.columns.single.name, 'Shifted');
        expect(result.parameters.single.name, 'n');
      },
      skip: liveSkip,
    );

    test('a declared parameter overrides the inference', () async {
      final result = await describe('''
-- name: q
-- param: code nvarchar
SELECT [Id] FROM [$schema].[Orders] WHERE [Code] = @code;
''');
      expect(result.parameters.single.sqlTypeName, 'nvarchar');
    }, skip: liveSkip);

    test('a query with no parameters describes none', () async {
      final result = await describe(
        '-- name: q\nSELECT [Id] FROM [$schema].[Orders];',
      );
      expect(result.parameters, isEmpty);
    }, skip: liveSkip);

    test('a stored procedure is described from its name', () async {
      final result = await describe('''
-- name: rapor
-- procedure: $schema.sp_Report
-- param: yil int
''');
      expect(result.columns.map((c) => c.name), <String>['Id', 'Code']);
      expect(result.parameters.single.name, 'yil');
    }, skip: liveSkip);

    test(
      'a temp table cannot be described, and the message says why',
      () async {
        await expectLater(
          describe('''
-- name: q
SELECT [A] INTO #t FROM (SELECT 1 AS [A]) AS s;
SELECT [A] FROM #t;
'''),
          throwsA(
            isA<UndescribableQuery>().having(
              (e) => e.reason,
              'reason',
              contains('temporary table'),
            ),
          ),
        );
      },
      skip: liveSkip,
    );

    test(
      'EXEC of a literal IS describable — the server folds the constant',
      () async {
        final result = await describe("-- name: q\nEXEC(N'SELECT 1 AS [A]');");
        expect(result.columns.single.name, 'A');
      },
      skip: liveSkip,
    );

    test(
      'EXEC of a variable is not describable, and the message says why',
      () async {
        await expectLater(
          describe(
            "-- name: q\n"
            "DECLARE @s NVARCHAR(100) = N'SELECT 1 AS [A]'; EXEC(@s);",
          ),
          throwsA(
            isA<UndescribableQuery>().having(
              (e) => e.reason,
              'reason',
              contains('dynamically'),
            ),
          ),
        );
      },
      skip: liveSkip,
    );

    test('sp_executesql of a variable is not describable either', () async {
      await expectLater(
        describe(
          "-- name: q\n"
          "DECLARE @s NVARCHAR(100) = N'SELECT 1'; EXEC sp_executesql @s;",
        ),
        throwsA(isA<UndescribableQuery>()),
      );
    }, skip: liveSkip);

    test('the message names the way out', () async {
      try {
        await describe(
          "-- name: q\nDECLARE @s NVARCHAR(50) = N'SELECT 1'; EXEC(@s);",
        );
        fail('expected UndescribableQuery');
      } on UndescribableQuery catch (error) {
        expect(error.toString(), contains('describe: manual'));
        expect(error.toString(), contains('q.sql'));
      }
    }, skip: liveSkip);

    test('a manual declaration bypasses the server entirely', () async {
      final result = await describe('''
-- name: gecici
-- describe: manual
-- column: A int not null
-- column: B nvarchar null
SELECT [A], [B] FROM #whatever;
''');
      expect(result.columns.map((c) => c.name), <String>['A', 'B']);
      expect(result.columns.first.nullable, isFalse);
      expect(result.columns.last.nullable, isTrue);
    }, skip: liveSkip);

    test(
      'an unaliased expression is caught, not silently named empty',
      () async {
        final result = await describe(
          '-- name: q\nSELECT COUNT(*) FROM [$schema].[Orders];',
        );
        expect(result.columns.single.name, isEmpty);
      },
      skip: liveSkip,
    );

    test('a returns: affected query is not described at all', () async {
      final result = await describe('''
-- name: q
-- returns: affected
DELETE FROM [$schema].[Orders] WHERE [Id] = @id;
''');
      expect(result.columns, isEmpty);
      expect(result.parameters.single.name, 'id');
    }, skip: liveSkip);
  });
}

