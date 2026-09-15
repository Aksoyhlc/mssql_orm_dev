import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/emitter.dart';
import 'package:mssql_orm_dev/src/generator.dart';
import 'package:test/test.dart';

import 'support/schemas.dart';

Map<Object?, Object?> yamlConfig({Object? softDeletes, Object? timestamps}) {
  final config = <Object?, Object?>{
    'connection': <Object?, Object?>{
      'host': 'localhost',
      'database': 'db',
      'user': 'sa',
      'password': 'dev-only',
    },
  };
  if (softDeletes != null) config['soft_delete_columns'] = softDeletes;
  if (timestamps != null) config['timestamps'] = timestamps;
  return config;
}

GeneratorConfig directConfig({
  Map<String, String> softDeletes = const <String, String>{},
  Map<String, TimestampColumnsConfig> timestamps =
      const <String, TimestampColumnsConfig>{},
  List<String> readOnly = const <String>[],
}) => GeneratorConfig(
  snapshotPath: 'tool/mssql_schema.json',
  connection: const MssqlConnectionConfig(
    host: 'localhost',
    database: 'db',
    username: 'sa',
    password: 'dev-only',
  ),
  output: 'unused/generated',
  modelsOutput: 'unused/models',
  queriesInput: 'unused/queries',
  schemas: const <String>{'dbo'},
  softDeleteColumns: softDeletes,
  timestampColumns: timestamps,
  readOnlyColumns: readOnly,
);

void main() {
  group('configuration parsing', () {
    test('reads soft-delete and timestamp conventions', () {
      final config = GeneratorConfig.fromMap(
        yamlConfig(
          softDeletes: <Object?, Object?>{'dbo.Orders': 'Precise'},
          timestamps: <Object?, Object?>{
            'dbo.Orders': <Object?, Object?>{
              'created': 'CreatedAt',
              'updated': 'Precise',
            },
          },
        ),
      );

      expect(config.softDeleteColumns['dbo.Orders'], 'Precise');
      expect(config.timestampColumns['dbo.Orders']?.createdColumn, 'CreatedAt');
      expect(config.timestampColumns['dbo.Orders']?.updatedColumn, 'Precise');
    });

    test('rejects malformed and empty timestamp blocks', () {
      expect(
        () => GeneratorConfig.fromMap(yamlConfig(timestamps: 'CreatedAt')),
        throwsA(isA<ConfigError>()),
      );
      expect(
        () => GeneratorConfig.fromMap(
          yamlConfig(
            timestamps: <Object?, Object?>{'dbo.Orders': <Object?, Object?>{}},
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects a malformed soft-delete mapping', () {
      expect(
        () => GeneratorConfig.fromMap(yamlConfig(softDeletes: 'DeletedAt')),
        throwsA(isA<ConfigError>()),
      );
      expect(
        () => GeneratorConfig.fromMap(
          yamlConfig(softDeletes: <Object?>['dbo.Orders', 'DeletedAt']),
        ),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('generated convention metadata', () {
    test('emits soft-delete and timestamp bindings', () {
      final config = directConfig(
        softDeletes: const <String, String>{'dbo.Orders': 'Precise'},
        timestamps: const <String, TimestampColumnsConfig>{
          'dbo.Orders': TimestampColumnsConfig(
            createdColumn: 'CreatedAt',
            updatedColumn: 'Precise',
          ),
        },
      );
      final source = emitGenerated(
        TablePlan.of(ordersTable, config),
        version: 'test',
      );

      expect(
        source,
        contains("softDelete: const MssqlSoftDelete(column: 'Precise')"),
      );
      expect(source, contains("createdColumn: 'CreatedAt'"));
      expect(source, contains("updatedColumn: 'Precise'"));
    });
  });

  group('schema validation', () {
    void validate(GeneratorConfig config) => Generator(
      config,
      version: 'test',
      dryRun: true,
    ).emitFor(<MssqlTableSchema>[ordersTable]);

    test('rejects unknown tables and columns', () {
      expect(
        () => validate(
          directConfig(
            softDeletes: const <String, String>{'dbo.Missing': 'DeletedAt'},
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
      expect(
        () => validate(
          directConfig(
            softDeletes: const <String, String>{'dbo.Orders': 'Missing'},
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test(
      'rejects non-nullable, generated and configured read-only columns',
      () {
        expect(
          () => validate(
            directConfig(
              softDeletes: const <String, String>{'dbo.Orders': 'Code'},
            ),
          ),
          throwsA(isA<ConfigError>()),
        );
        expect(
          () => validate(
            directConfig(
              timestamps: const <String, TimestampColumnsConfig>{
                'dbo.Orders': TimestampColumnsConfig(updatedColumn: 'NetTotal'),
              },
            ),
          ),
          throwsA(isA<ConfigError>()),
        );
        expect(
          () => validate(
            directConfig(
              timestamps: const <String, TimestampColumnsConfig>{
                'dbo.Orders': TimestampColumnsConfig(updatedColumn: 'Precise'),
              },
              readOnly: const <String>['dbo.Orders.Precise'],
            ),
          ),
          throwsA(isA<ConfigError>()),
        );
        expect(
          () => validate(
            directConfig(
              timestamps: const <String, TimestampColumnsConfig>{
                'dbo.Orders': TimestampColumnsConfig(updatedColumn: 'IsOpen'),
              },
            ),
          ),
          throwsA(isA<ConfigError>()),
        );
        expect(
          () => validate(
            directConfig(
              softDeletes: const <String, String>{'dbo.Orders': 'Discount'},
            ),
          ),
          throwsA(isA<ConfigError>()),
        );
      },
    );

    test('rejects using one column for both timestamps', () {
      expect(
        () => validate(
          directConfig(
            timestamps: const <String, TimestampColumnsConfig>{
              'dbo.Orders': TimestampColumnsConfig(
                createdColumn: 'Precise',
                updatedColumn: 'precise',
              ),
            },
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('rejects reusing the soft-delete column as a timestamp', () {
      expect(
        () => validate(
          directConfig(
            softDeletes: const <String, String>{'dbo.Orders': 'Precise'},
            timestamps: const <String, TimestampColumnsConfig>{
              'dbo.Orders': TimestampColumnsConfig(updatedColumn: 'precise'),
            },
          ),
        ),
        throwsA(isA<ConfigError>()),
      );
    });
  });
}
