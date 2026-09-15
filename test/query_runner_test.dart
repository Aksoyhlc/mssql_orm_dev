import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:mssql_orm_dev/src/query_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_connection.dart';

void main() {
  late Directory root;
  late String queries;
  late String output;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mssql_query_runner');
    queries = p.join(root.path, 'queries');
    output = p.join(root.path, 'generated');
    Directory(queries).createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  GeneratorConfig config() => GeneratorConfig(
    snapshotPath: 'tool/mssql_schema.json',
    connection: const MssqlConnectionConfig(
      host: 'h',
      database: 'd',
      username: 'u',
      password: 'p',
    ),
    output: output,
    modelsOutput: p.join(root.path, 'models'),
    queriesInput: queries,
    schemas: const <String>{'dbo'},
  );

  void writeQuery(
    String path, {
    required String name,
    String sql = 'SELECT 1 AS Id;',
    String columns = 'Id int not null',
  }) {
    final file = File(p.join(queries, path))
      ..parent.createSync(recursive: true);
    file.writeAsStringSync('''
-- name: $name
-- describe: manual
-- column: $columns
$sql
''');
  }

  String generatedPath() => p.join(output, 'queries.g.dart');

  group('loadQueryFiles', () {
    test('returns nothing when the directory does not exist', () {
      expect(loadQueryFiles(p.join(root.path, 'absent')), isEmpty);
    });

    test('returns nothing when the directory is empty', () {
      expect(loadQueryFiles(queries), isEmpty);
    });

    test('finds files in nested folders', () {
      writeQuery('reports/monthly.sql', name: 'monthly');
      final loaded = loadQueryFiles(queries);
      expect(loaded, hasLength(1));
      expect(loaded.single.name, 'monthly');
    });

    test('records the path relative to the queries root', () {
      writeQuery('reports/monthly.sql', name: 'monthly');
      expect(
        loadQueryFiles(queries).single.sourcePath,
        isNot(contains(root.path)),
      );
      expect(
        loadQueryFiles(queries).single.sourcePath,
        endsWith('monthly.sql'),
      );
    });

    test('sorts by path, so two runs produce the same file', () {
      writeQuery('c.sql', name: 'third');
      writeQuery('a.sql', name: 'first');
      writeQuery('b.sql', name: 'second');
      expect(loadQueryFiles(queries).map((q) => q.name), <String>[
        'first',
        'second',
        'third',
      ]);
    });

    test('ignores anything that is not .sql', () {
      File(p.join(queries, 'notes.md')).writeAsStringSync('-- name: x');
      writeQuery('real.sql', name: 'real');
      expect(loadQueryFiles(queries).map((q) => q.name), <String>['real']);
    });

    test('a malformed file names itself in the error', () {
      File(p.join(queries, 'broken.sql')).writeAsStringSync('SELECT 1;');
      expect(
        () => loadQueryFiles(queries),
        throwsA(
          isA<QueryFileError>()
              .having((e) => e.path, 'path', 'broken.sql')
              .having((e) => e.message, 'message', contains('-- name:')),
        ),
      );
    });
  });

  group('generateQueries', () {
    test('writes the file and reports how many queries it holds', () async {
      writeQuery('a.sql', name: 'first');
      writeQuery('b.sql', name: 'second');
      final count = await generateQueries(
        FakeConnection(),
        config(),
        version: '0.1.0',
      );
      expect(count, 2);
      final source = File(generatedPath()).readAsStringSync();
      expect(source, contains('first('));
      expect(source, contains('second('));
    });

    test('creates the output directory rather than failing', () async {
      writeQuery('a.sql', name: 'first');
      expect(Directory(output).existsSync(), isFalse);
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      expect(File(generatedPath()).existsSync(), isTrue);
    });

    test('writes valid, formatted Dart', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      final source = File(generatedPath()).readAsStringSync();
      expect(source, contains('class FirstRow {'));
      expect(source, isNot(contains('\t')));
    });

    test('with no queries at all it writes nothing', () async {
      expect(
        await generateQueries(FakeConnection(), config(), version: '0.1.0'),
        0,
      );
      expect(File(generatedPath()).existsSync(), isFalse);
    });

    test('a dry run describes everything but writes nothing', () async {
      writeQuery('a.sql', name: 'first');
      final count = await generateQueries(
        FakeConnection(),
        config(),
        version: '0.1.0',
        dryRun: true,
      );
      expect(count, 1);
      expect(File(generatedPath()).existsSync(), isFalse);
    });

    test('two files sharing a method name stop the run', () async {
      writeQuery('a.sql', name: 'ordersByCustomer');
      writeQuery('b.sql', name: 'ordersByCustomer');
      await expectLater(
        generateQueries(FakeConnection(), config(), version: '0.1.0'),
        throwsA(
          isA<QueryFileError>()
              .having((e) => e.path, 'path', 'b.sql')
              .having((e) => e.message, 'message', contains('a.sql')),
        ),
      );
      expect(File(generatedPath()).existsSync(), isFalse);
    });

    test('a manual query never reaches the server', () async {
      final fake = FakeConnection();
      writeQuery('a.sql', name: 'first');
      await generateQueries(fake, config(), version: '0.1.0');
      expect(fake.calls, isEmpty);
    });
  });

  group('verifyQueries', () {
    FakeConnection confirming({
      int queries = 1,
      String name = 'Id',
      String type = 'int',
      bool nullable = false,
    }) {
      final fake = FakeConnection();
      for (var i = 0; i < queries; i++) {
        fake.replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'column_ordinal': 1,
            'name': name,
            'system_type_name': type,
            'is_nullable': nullable,
            'max_length': 0,
            'precision': 0,
            'scale': 0,
          },
        ]);
      }
      return fake;
    }

    Future<List<QueryDrift>> verify({int queries = 1}) =>
        verifyQueries(confirming(queries: queries), config(), version: '0.1.0');

    test('says so when nothing has been generated yet', () async {
      writeQuery('a.sql', name: 'first');
      final drift = await verify();
      expect(drift, hasLength(1));
      expect(drift.single.message, contains('Generate first'));
    });

    test('is silent when the file matches the queries', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      expect(await verify(), isEmpty);
    });

    test('notices a query whose columns changed', () async {
      writeQuery('a.sql', name: 'first', columns: 'Id int not null');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      writeQuery('a.sql', name: 'first', columns: 'Id nvarchar null');
      final drift = await verify();
      expect(drift.map((d) => d.message), contains(contains('Regenerate')));
    });

    test('the server disagreeing with a manual declaration is drift', () async {
      writeQuery('a.sql', name: 'first', columns: 'Id int not null');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      final drift = await verifyQueries(
        confirming(type: 'bigint'),
        config(),
        version: '0.1.0',
      );
      expect(
        drift.map((d) => d.message),
        contains(contains('the server reports bigint')),
      );
    });

    test(
      'a manual query the server cannot describe is reported, not passed',
      () async {
        writeQuery('a.sql', name: 'first');
        await generateQueries(FakeConnection(), config(), version: '0.1.0');
        final drift = await verifyQueries(
          FakeConnection(),
          config(),
          version: '0.1.0',
        );
        expect(
          drift.map((d) => d.message),
          contains(contains('could not describe')),
        );
      },
    );

    test('notices a query that was added', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      writeQuery('b.sql', name: 'second');
      expect(await verify(queries: 2), hasLength(1));
    });

    test('notices a query that was removed', () async {
      writeQuery('a.sql', name: 'first');
      writeQuery('b.sql', name: 'second');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      File(p.join(queries, 'b.sql')).deleteSync();
      expect(await verify(), hasLength(1));
    });

    test('a manual query that still matches is silent', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      expect(await verify(), isEmpty);
    });

    test('a generator version bump alone is not drift', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      expect(
        await verifyQueries(confirming(), config(), version: '9.9.9'),
        isEmpty,
      );
    });

    test('writes nothing, so it is safe on a read-only checkout', () async {
      writeQuery('a.sql', name: 'first');
      await generateQueries(FakeConnection(), config(), version: '0.1.0');
      final before = File(generatedPath()).readAsStringSync();
      writeQuery('a.sql', name: 'first', columns: 'Id nvarchar null');
      await verify();
      expect(File(generatedPath()).readAsStringSync(), before);
    });
  });
}

