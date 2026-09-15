import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/schemas.dart';

List<MssqlTableSchema> get everyShape => <MssqlTableSchema>[
  ordersTable,
  table(
    'Customers',
    primaryKey: const <String>['Id'],
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      column('Name', 'nvarchar', ordinal: 2, maxLength: 200),
      column('Note', 'nvarchar', ordinal: 3, nullable: true, maxLength: -1),
    ],
  ),
  table(
    'Lines',
    primaryKey: const <String>['OrderId', 'LineNo'],
    columns: <MssqlColumnSchema>[
      column('OrderId', 'int'),
      column('LineNo', 'int', ordinal: 2),
      column('Qty', 'int', ordinal: 3),
    ],
  ),
  table(
    'Triggered',
    primaryKey: const <String>['Id'],
    hasEnabledTrigger: true,
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
    ],
  ),
  table(
    'NoKey',
    columns: <MssqlColumnSchema>[
      column('A', 'int'),
      column('B', 'nvarchar', ordinal: 2, nullable: true, maxLength: 100),
    ],
  ),
  table(
    'OpenOrders',
    isView: true,
    columns: <MssqlColumnSchema>[
      column('Id', 'int'),
      column('Code', 'varchar', ordinal: 2, maxLength: 20),
    ],
  ),
  table(
    'Places',
    primaryKey: const <String>['Id'],
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      column('Shape', 'geography', ordinal: 2, nullable: true),
      column('Region', 'hierarchyid', ordinal: 3, nullable: true),
    ],
  ),
  table(
    'Awkward',
    primaryKey: const <String>['Id'],
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      column('default', 'nvarchar', ordinal: 2, maxLength: 100),
      column('2024Total', 'decimal', ordinal: 3, precision: 18, scale: 2),
      column('HTTPStatus', 'int', ordinal: 4),
      column('CRTDT', 'datetime2', ordinal: 5, scale: 3),
    ],
  ),
  table(
    'AllTypes',
    primaryKey: const <String>['Id'],
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      for (final entry in <String>[
        'bit',
        'tinyint',
        'smallint',
        'bigint',
        'real',
        'float',
        'decimal',
        'numeric',
        'money',
        'smallmoney',
        'char',
        'varchar',
        'nchar',
        'nvarchar',
        'text',
        'ntext',
        'xml',
        'binary',
        'varbinary',
        'image',
        'date',
        'smalldatetime',
        'datetime',
        'uniqueidentifier',
      ].indexed.map((e) => (index: e.$1, name: e.$2)))
        column(
          'c_${entry.name}',
          entry.name,
          ordinal: entry.index + 2,
          nullable: entry.index.isEven,
          maxLength: 50,
          precision: 18,
          scale: 4,
        ),
    ],
  ),
];

GeneratorConfig configFor(
  String root, {
  required bool scaffold,
  required MssqlDecimalMode decimalMode,
  required bool json,
}) => GeneratorConfig(
  snapshotPath: 'tool/mssql_schema.json',
  connection: const MssqlConnectionConfig(
    host: 'h',
    database: 'd',
    username: 'u',
    password: 'p',
  ),
  output: p.join(root, 'lib', 'db', 'generated'),
  modelsOutput: p.join(root, 'lib', 'db', 'models'),
  extensionsOutput: p.join(root, 'lib', 'db', 'extensions'),
  queriesInput: p.join(root, 'lib', 'db', 'queries'),
  schemas: const <String>{'dbo'},
  scaffold: scaffold,
  decimalMode: decimalMode,
  json: json,
);

Future<ProcessResult> analyseGenerated({
  required bool scaffold,
  required MssqlDecimalMode decimalMode,
  required bool json,
}) async {
  final ormPath = p.normalize(
    p.join(Directory.current.path, '..', 'mssql_orm'),
  );
  final driverPath = p.normalize(
    p.join(Directory.current.path, '..', 'mssql_native'),
  );

  final root = Directory.systemTemp.createTempSync('mssql_orm_gen_');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: generated_fixture
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  meta: ^1.12.0
  mssql_native:
    path: $driverPath
  mssql_orm:
    path: $ormPath

# An override in a dependency's pubspec does not reach the package that
# depends on it, so a consuming application repeats it until the driver is
# published. The README says the same thing to real users.
dependency_overrides:
  mssql_native:
    path: $driverPath
  mssql_orm:
    path: $ormPath
''');
  File(
    p.join(root.path, 'analysis_options.yaml'),
  ).writeAsStringSync('include: package:lints/recommended.yaml\n');

  Generator(
    configFor(
      root.path,
      scaffold: scaffold,
      decimalMode: decimalMode,
      json: json,
    ),
    version: 'test',
  ).emitFor(everyShape);

  final orders = File(
    p.join(root.path, 'lib', 'db', 'generated', 'orders.g.dart'),
  ).readAsStringSync();
  if (!orders.contains('abstract final class OrdersRel')) {
    fail('No relations were generated:\n$orders');
  }

  final get = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: root.path);
  if (get.exitCode != 0) {
    fail('dart pub get failed:\n${get.stdout}\n${get.stderr}');
  }
  return Process.run('dart', <String>[
    'analyze',
    'lib',
  ], workingDirectory: root.path);
}

void main() {
  group('the generated package analyses cleanly', () {
    test('with scaffolding, which is the default shape', () async {
      final result = await analyseGenerated(
        scaffold: true,
        decimalMode: MssqlDecimalMode.doublePrecision,
        json: false,
      );
      expect(
        result.exitCode,
        0,
        reason: 'dart analyze reported:\n${result.stdout}\n${result.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('without scaffolding', () async {
      final result = await analyseGenerated(
        scaffold: false,
        decimalMode: MssqlDecimalMode.doublePrecision,
        json: false,
      );
      expect(
        result.exitCode,
        0,
        reason: 'dart analyze reported:\n${result.stdout}\n${result.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('with exact decimals and JSON on', () async {
      final result = await analyseGenerated(
        scaffold: true,
        decimalMode: MssqlDecimalMode.text,
        json: true,
      );
      expect(
        result.exitCode,
        0,
        reason: 'dart analyze reported:\n${result.stdout}\n${result.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}

