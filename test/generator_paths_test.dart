import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/schemas.dart';

GeneratorConfig configIn(String root) => GeneratorConfig(
  snapshotPath: 'tool/mssql_schema.json',
  connection: const MssqlConnectionConfig(
    host: 'h',
    database: 'd',
    username: 'u',
    password: 'p',
  ),
  output: p.join(root, 'lib', 'db', 'generated'),
  modelsOutput: p.join(root, 'lib', 'db', 'models'),
  queriesInput: p.join(root, 'lib', 'db', 'queries'),
  schemas: const <String>{'dbo'},
);

List<MssqlTableSchema> get tables => <MssqlTableSchema>[
  table(
    'Users',
    primaryKey: const <String>['Id'],
    columns: <MssqlColumnSchema>[
      column('Id', 'int', isIdentity: true),
      column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
    ],
  ),
];

Directory makeRoot() {
  final root = Directory.systemTemp.createTempSync('gen_paths_');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

void main() {
  group('a second run with nothing changed', () {
    test('rewrites no file and reports them unchanged', () {
      final root = makeRoot();
      final config = configIn(root.path);

      final first = Generator(config, version: 't').emitFor(tables);
      expect(first.written, isNotEmpty);
      expect(first.unchanged, isEmpty);

      final second = Generator(config, version: 't').emitFor(tables);
      expect(second.written, isEmpty);
      expect(second.unchanged, isNotEmpty);
      expect(second.changed, isFalse);
    });

    test('a changed schema is reported as changed', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);

      final widened = <MssqlTableSchema>[
        table(
          'Users',
          primaryKey: const <String>['Id'],
          columns: <MssqlColumnSchema>[
            column('Id', 'int', isIdentity: true),
            column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
            column(
              'Email',
              'nvarchar',
              ordinal: 3,
              nullable: true,
              maxLength: 200,
            ),
          ],
        ),
      ];
      final result = Generator(config, version: 't').emitFor(widened);
      expect(result.changed, isTrue);
      expect(result.written, isNotEmpty);
    });

    test('a dry run reports the same thing and writes nothing', () {
      final root = makeRoot();
      final config = configIn(root.path);
      final planned = Generator(
        config,
        version: 't',
        dryRun: true,
      ).emitFor(tables);
      expect(planned.changed, isTrue);
      expect(
        Directory(p.join(root.path, 'lib', 'db', 'generated')).existsSync(),
        isFalse,
      );
    });
  });

  group('stale files', () {
    test('a generated file for a table that is gone is removed', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(<MssqlTableSchema>[
        ...tables,
        table(
          'Old',
          primaryKey: const <String>['Id'],
          columns: <MssqlColumnSchema>[column('Id', 'int')],
        ),
      ]);
      final old = File(
        p.join(root.path, 'lib', 'db', 'generated', 'old.g.dart'),
      );
      expect(old.existsSync(), isTrue);

      final result = Generator(config, version: 't').emitFor(tables);
      expect(result.deleted.map(p.basename), contains('old.g.dart'));
      expect(old.existsSync(), isFalse);
    });

    test('queries.g.dart is left alone: another pass owns it', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);

      final queries = File(
        p.join(root.path, 'lib', 'db', 'generated', 'queries.g.dart'),
      )..writeAsStringSync('// written by the query pass\n');


      final result = Generator(config, version: 't').emitFor(tables);
      expect(result.deleted, isEmpty);
      expect(queries.existsSync(), isTrue);
      expect(result.changed, isFalse);
    });

    test('a hand-written file in the generated directory is left alone', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      final mine = File(p.join(root.path, 'lib', 'db', 'generated', 'notes.md'))
        ..writeAsStringSync('mine');
      Generator(config, version: 't').emitFor(tables);
      expect(mine.existsSync(), isTrue);
    });
  });

  group('scaffolds', () {
    test('are created once and never rewritten', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      final scaffold = File(
        p.join(root.path, 'lib', 'db', 'models', 'users.dart'),
      );
      scaffold.writeAsStringSync('// my own code\n');


      final result = Generator(config, version: 't').emitFor(tables);
      expect(result.scaffolded, isEmpty);
      expect(result.skippedScaffolds, isNotEmpty);
      expect(scaffold.readAsStringSync(), '// my own code\n');

    });

    test('re-export the generated half, so one import per table is enough', () {
      final root = makeRoot();
      Generator(configIn(root.path), version: 't').emitFor(tables);
      final scaffold = File(
        p.join(root.path, 'lib', 'db', 'models', 'users.dart'),
      ).readAsStringSync();
      expect(scaffold, contains("export '../generated/users.g.dart';"));
    });
  });

  group('--only', () {
    List<MssqlTableSchema> twoTables() => <MssqlTableSchema>[
      ...tables,
      table(
        'Orders',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('UserId', 'int', ordinal: 2),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          MssqlForeignKeySchema(
            name: 'FK_Orders_Users',
            columns: <String>['UserId'],
            referencedSchema: 'dbo',
            referencedTable: 'Users',
            referencedColumns: <String>['Id'],
          ),
        ],
      ),
    ];

    test('writes only the table it was given', () {
      final root = makeRoot();
      final config = configIn(root.path);
      final result = Generator(
        config,
        version: 't',
        only: <String>['dbo.Orders'],
      ).emitFor(twoTables());
      expect(result.written.map(p.basename), <String>['orders.g.dart']);
      expect(File(p.join(config.output, 'users.g.dart')).existsSync(), isFalse);
      root.deleteSync(recursive: true);
    });

    test('names the table either way, like every other setting', () {
      final root = makeRoot();
      final result = Generator(
        configIn(root.path),
        version: 't',
        only: <String>['orders'],
      ).emitFor(twoTables());
      expect(result.written.map(p.basename), <String>['orders.g.dart']);
      root.deleteSync(recursive: true);
    });

    test('writes what a full run would write for that table', () {
      final full = makeRoot();
      Generator(configIn(full.path), version: 't').emitFor(twoTables());
      final whole = File(
        p.join(configIn(full.path).output, 'orders.g.dart'),
      ).readAsStringSync();

      final partial = makeRoot();
      Generator(
        configIn(partial.path),
        version: 't',
        only: <String>['dbo.Orders'],
      ).emitFor(twoTables());
      expect(
        File(
          p.join(configIn(partial.path).output, 'orders.g.dart'),
        ).readAsStringSync(),
        whole,
      );
      expect(whole, contains('UsersRow? get user'));

      full.deleteSync(recursive: true);
      partial.deleteSync(recursive: true);
    });

    test('does not delete the files it was not asked to write', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(twoTables());
      expect(File(p.join(config.output, 'users.g.dart')).existsSync(), isTrue);

      final result = Generator(
        config,
        version: 't',
        only: <String>['dbo.Orders'],
      ).emitFor(twoTables());
      expect(result.deleted, isEmpty);
      expect(File(p.join(config.output, 'users.g.dart')).existsSync(), isTrue);
      root.deleteSync(recursive: true);
    });

    test('leaves the barrel alone, which would otherwise lose a table', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(twoTables());
      final barrel = File(p.join(config.output, 'generated.dart'));
      final before = barrel.readAsStringSync();
      expect(before, contains('users.dart'));

      Generator(
        config,
        version: 't',
        only: <String>['dbo.Orders'],
      ).emitFor(twoTables());
      expect(barrel.readAsStringSync(), before);
      root.deleteSync(recursive: true);
    });

    test('a name that matches no table stops the run before writing', () {
      final root = makeRoot();
      final config = configIn(root.path);
      expect(
        () => Generator(
          config,
          version: 't',
          only: <String>['dbo.Ordres'],
        ).emitFor(twoTables()),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dbo.Ordres'), contains('Nothing was written')),
          ),
        ),
      );
      expect(Directory(config.output).existsSync(), isFalse);
      root.deleteSync(recursive: true);
    });

    test('an empty list is a full run', () {
      final root = makeRoot();
      final result = Generator(
        configIn(root.path),
        version: 't',
        only: const <String>[],
      ).emitFor(twoTables());
      expect(result.written.map(p.basename), contains('users.g.dart'));
      expect(result.written.map(p.basename), contains('generated.dart'));
      root.deleteSync(recursive: true);
    });
  });

  group('the barrel', () {
    String barrelIn(GeneratorConfig config) =>
        File(p.join(config.output, 'generated.dart')).readAsStringSync();

    test('exports the models, not the generated halves', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      expect(barrelIn(config), contains("export '../models/users.dart';"));
      final tableExports = barrelIn(config)
          .split('\n')
          .where((line) => line.startsWith('export '))
          .where((line) => !line.contains('database.g.dart'))
          .where((line) => !line.contains('queries.g.dart'))
          .where((line) => !line.contains('procedures.g.dart'));
      expect(tableExports, everyElement(isNot(contains('.g.dart'))));
      root.deleteSync(recursive: true);
    });

    test('exports the generated files when there are no models', () {
      final root = makeRoot();
      final config = GeneratorConfig(
        snapshotPath: 'tool/mssql_schema.json',
        connection: configIn(root.path).connection,
        output: configIn(root.path).output,
        modelsOutput: configIn(root.path).modelsOutput,
        queriesInput: configIn(root.path).queriesInput,
        schemas: const <String>{'dbo'},
        scaffold: false,
      );
      Generator(config, version: 't').emitFor(tables);
      expect(barrelIn(config), contains("export 'users.g.dart';"));
      root.deleteSync(recursive: true);
    });

    test('uses forward slashes, which a Dart URI needs on any platform', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      expect(barrelIn(config), isNot(contains(r'\\')));
      root.deleteSync(recursive: true);
    });

    test('carries the database class, which no scaffold re-exports', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      expect(barrelIn(config), contains("export 'database.g.dart';"));
      root.deleteSync(recursive: true);
    });

    test('names every table exactly once', () {
      final root = makeRoot();
      final config = configIn(root.path);
      Generator(config, version: 't').emitFor(tables);
      final exports = barrelIn(
        config,
      ).split('\n').where((line) => line.startsWith('export ')).toList();
      final tableExports = exports
          .where((line) => !line.contains('database.g.dart'))
          .toList();
      expect(tableExports, hasLength(tables.length));
      expect(tableExports.toSet(), hasLength(tables.length));
      root.deleteSync(recursive: true);
    });
  });
}

