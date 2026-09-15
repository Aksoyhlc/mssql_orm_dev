import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/emitter.dart';
import 'package:mssql_orm_dev/src/schema_drift.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/catalog_rows.dart';

Map<String, Object?> pk(int objectId, String column, {int ordinal = 1}) =>
    <String, Object?>{
      'object_id': objectId,
      'index_name': 'PK_$objectId',
      'column_name': column,
      'key_ordinal': ordinal,
    };

void main() {
  late Directory root;
  late String output;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mssql_drift');
    output = p.join(root.path, 'generated');
    Directory(output).createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  GeneratorConfig config({
    Set<String> schemas = const <String>{'dbo'},
    bool includeViews = true,
    List<String> include = const <String>['*'],
    List<String> exclude = const <String>['sysdiagrams'],
  }) => GeneratorConfig(
    snapshotPath: 'tool/mssql_schema.json',
    connection: const MssqlConnectionConfig(
      host: 'h',
      database: 'd',
      username: 'u',
      password: 'p',
    ),
    output: output,
    modelsOutput: p.join(root.path, 'models'),
    queriesInput: p.join(root.path, 'queries'),
    schemas: schemas,
    includeViews: includeViews,
    include: include,
    exclude: exclude,
  );

  CatalogRows catalog({bool extraColumn = false, String table = 'Orders'}) =>
      CatalogRows(
        objects: <Map<String, Object?>>[object(1, table)],
        columns: <Map<String, Object?>>[
          col(1, 1, 'Id', 'int', identity: true),
          col(1, 2, 'Total', 'decimal', precision: 18, scale: 2),
          if (extraColumn) col(1, 3, 'Note', 'nvarchar', maxLength: 100),
        ],
        primaryKeys: <Map<String, Object?>>[pk(1, 'Id')],
      );

  Future<void> generateFrom(CatalogRows rows, GeneratorConfig cfg) async {
    final tables = await MssqlSchemaReader(rows.connection).readTables(
      schemas: cfg.schemas,
      includeViews: cfg.includeViews,
      include: cfg.include,
      exclude: cfg.exclude,
    );
    for (final table in tables) {
      final plan = TablePlan.of(table, cfg, world: tables);
      File(p.join(cfg.output, '${plan.fileName}.g.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(emitGenerated(plan, version: '0.1.0'));
    }
  }

  Future<MssqlSchemaReport> check(CatalogRows rows, [GeneratorConfig? cfg]) =>
      checkGeneratedSchema(rows.connection, cfg ?? config());

  group('readGeneratedStamps', () {
    test('finds nothing when the output directory does not exist', () {
      expect(readGeneratedStamps(p.join(root.path, 'absent')), isEmpty);
    });

    test('reads the table and fingerprint out of the header', () async {
      await generateFrom(catalog(), config());
      final stamps = readGeneratedStamps(output);
      expect(stamps, hasLength(1));
      expect(stamps.single.qualifiedName, 'dbo.Orders');
      expect(stamps.single.fingerprint, isNotEmpty);
    });

    test('skips queries.g.dart, which stands for no table', () async {
      await generateFrom(catalog(), config());
      File(
        p.join(output, 'queries.g.dart'),
      ).writeAsStringSync('// GENERATED — do not edit.\n');

      expect(readGeneratedStamps(output), hasLength(1));
    });

    test('skips a file that carries no header', () async {
      File(p.join(output, 'notes.g.dart')).writeAsStringSync('class A {}\n');
      expect(readGeneratedStamps(output), isEmpty);
    });

    test('ignores files that are not .g.dart', () async {
      await generateFrom(catalog(), config());
      File(
        p.join(output, 'order.dart'),
      ).writeAsStringSync('// Source: dbo.Fake\n// Schema fingerprint: abc\n');

      expect(readGeneratedStamps(output), hasLength(1));
    });

    test('stops reading at the first line of code', () async {
      File(p.join(output, 'orders.g.dart')).writeAsStringSync(
        '// Source: dbo.Orders\n'

        '// Schema fingerprint: real\n'

        'class Order {}\n'
        '// Schema fingerprint: fake\n',

      );
      expect(readGeneratedStamps(output).single.fingerprint, 'real');
    });
  });

  group('checkGeneratedSchema', () {
    test(
      'is clean when the generated code was made from this schema',
      () async {
        await generateFrom(catalog(), config());
        final report = await check(catalog());
        expect(report.isClean, isTrue, reason: report.describe());
        expect(report.describe(), contains('matches the database'));
      },
    );

    test('reports a table whose shape changed, as breaking', () async {
      await generateFrom(catalog(), config());
      final report = await check(catalog(extraColumn: true));
      expect(report.hasBreakingChanges, isTrue);
      expect(
        report.differences.single.kind,
        MssqlDifferenceKind.schemaFingerprintChanged,
      );
      expect(report.differences.single.table, 'dbo.Orders');
    });

    test('the change it reports says which file to regenerate', () async {
      await generateFrom(catalog(), config());
      final report = await check(catalog(extraColumn: true));
      expect(report.differences.single.remedy, contains('orders.g.dart'));
      expect(report.differences.single.remedy, contains('Regenerate'));
    });

    test('reports a generated table the database no longer has', () async {
      await generateFrom(catalog(), config());
      final report = await check(CatalogRows());
      expect(report.hasBreakingChanges, isTrue);
      expect(report.differences.single.kind, MssqlDifferenceKind.tableMissing);
    });

    test(
      'reports a table nobody has generated for, but calls it benign',
      () async {
        final report = await check(catalog());
        expect(report.differences, hasLength(1));
        expect(
          report.differences.single.kind,
          MssqlDifferenceKind.tableUngenerated,
        );
        expect(report.hasBreakingChanges, isFalse);
        expect(report.isClean, isFalse);
      },
    );

    test('an empty database with nothing generated is clean', () async {
      expect((await check(CatalogRows())).isClean, isTrue);
    });

    test('matches the table name without regard to case', () async {
      await generateFrom(catalog(), config());
      final path = p.join(output, 'orders.g.dart');
      final file = File(path);
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst(
          '// Source: dbo.Orders',

          '// Source: DBO.ORDERS',

        ),
      );
      expect((await check(catalog())).isClean, isTrue);
    });

    test('a table excluded by the configuration reads as missing', () async {
      await generateFrom(catalog(), config());
      final report = await check(
        catalog(),
        config(exclude: const <String>['Orders']),
      );
      expect(report.differences.single.kind, MssqlDifferenceKind.tableMissing);
      expect(report.differences.single.remedy, contains('excluded'));
    });

    test('the filters reach the reader rather than being ignored', () async {
      final connection = catalog().connection;
      await checkGeneratedSchema(
        connection,
        config(schemas: const <String>{'dbo', 'sales'}, includeViews: false),
      );
      final call = connection.calls.first;
      expect(call.bound('s0'), 'dbo');
      expect(call.bound('s1'), 'sales');
      expect(call.sql, contains("o.type IN ('U')"));
    });

    test('writes nothing, so it is safe on a read-only checkout', () async {
      await generateFrom(catalog(), config());
      final before = File(p.join(output, 'orders.g.dart')).readAsStringSync();
      await check(catalog(extraColumn: true));
      expect(File(p.join(output, 'orders.g.dart')).readAsStringSync(), before);
      expect(Directory(output).listSync(), hasLength(1));
    });
  });

  group('the connection', () {
    test('is only read from, never written to', () async {
      final connection = catalog().connection;
      await checkGeneratedSchema(connection, config());
      expect(connection.calls, isNotEmpty);
      expect(
        connection.calls.every((c) => c.member == 'queryRows'),
        isTrue,
        reason: connection.calls.map((c) => c.member).toString(),
      );
    });
  });
}

