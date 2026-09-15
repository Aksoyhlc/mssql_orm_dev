import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/dart_type.dart';
import 'package:mssql_orm_dev/src/emitter.dart';
import 'package:mssql_orm_dev/src/naming.dart';
import 'package:test/test.dart';

import 'support/schemas.dart';

GeneratorConfig config({
  bool scaffold = true,
  MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
  bool json = false,
  Map<String, String> classNames = const <String, String>{},
  Map<String, String> fieldNames = const <String, String>{},
  List<String> readOnlyColumns = const <String>[],
  List<String> hiddenColumns = const <String>[],
  Map<String, String?> softDeleteColumns = const <String, String?>{},
  ConventionsConfig conventions = const ConventionsConfig(),
  Map<String, TimestampColumnsConfig> timestampColumns =
      const <String, TimestampColumnsConfig>{},
}) => GeneratorConfig(
  snapshotPath: 'tool/mssql_schema.json',
  connection: const MssqlConnectionConfig(
    host: 'h',
    database: 'd',
    username: 'u',
    password: 'p',
  ),
  output: 'lib/db/generated',
  modelsOutput: 'lib/db/models',
  queriesInput: 'lib/db/queries',
  schemas: const <String>{'dbo'},
  scaffold: scaffold,
  decimalMode: decimalMode,
  json: json,
  classNames: classNames,
  fieldNames: fieldNames,
  readOnlyColumns: readOnlyColumns,
  hiddenColumns: hiddenColumns,
  softDeleteColumns: softDeleteColumns,
  conventions: conventions,
  timestampColumns: timestampColumns,
);

String generate(GeneratorConfig c, [MssqlTableSchema? schema]) =>
    emitGenerated(TablePlan.of(schema ?? ordersTable, c), version: '0.1.0');

void main() {
  mainNullableDefault();
  group('the generated file', () {
    test('says what it is and where the fingerprint came from', () {
      final source = generate(config());
      expect(source, contains('GENERATED — do not edit'));
      expect(source, contains('Source: dbo.Orders'));
      expect(source, contains('Schema fingerprint: '));
      expect(source, contains('Generator: mssql_orm_dev 0.1.0'));
    });

    test(
      'records foreign keys as a comment, since nothing generates from them yet',
      () {
        expect(
          generate(config()),
          contains('CustomerId -> dbo.Customers (Id)'),
        );
      },
    );

    test('points at the file you own', () {
      expect(
        generate(config()),
        contains('Application code belongs in ../models/orders.dart'),
      );
    });

    test('is byte-identical between two runs of the same schema', () {
      expect(generate(config()), generate(config()));
    });
  });

  group('the row class', () {
    test('scaffolding on names the generated class Base', () {
      final source = generate(config());
      expect(source, contains('class OrdersRowBase {'));
      expect(source, contains('static OrdersRow fromRow(MssqlRow row)'));
    });

    test('scaffolding off generates the concrete class directly', () {
      final source = generate(config(scaffold: false));
      expect(source, contains('class OrdersRow {'));
      expect(source, isNot(contains('OrdersRowBase')));
      expect(source, isNot(contains("import '../models/")));
    });

    test('nullability follows the column', () {
      final source = generate(config());
      expect(source, contains('final String code;'));
      expect(source, contains('final double? discount;'));
    });

    test('rows are read by ordinal after the names are checked', () {
      expect(
        generate(config()),
        contains('row.assertOrdinalNames(columnOrder)'),
      );
      expect(generate(config()), contains('row.at(0)'));
    });
  });

  group('type mapping', () {
    String field(
      String name, {
      MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
    }) {
      final source = generate(config(decimalMode: decimalMode));
      final match = RegExp('final ([A-Za-z0-9<>?]+) $name;').firstMatch(source);
      return match?.group(1) ?? 'MISSING';
    }

    test('integers, floats and booleans', () {
      expect(field('id'), 'int');
      expect(field('isOpen'), 'bool');
    });

    test('decimal follows the flag, in both directions', () {
      expect(field('total'), 'double');
      expect(field('total', decimalMode: MssqlDecimalMode.text), 'String');
      expect(field('discount'), 'double?');
      expect(field('discount', decimalMode: MssqlDecimalMode.text), 'String?');
    });

    test('a low-scale datetime2 becomes DateTime', () {
      expect(field('createdAt'), 'DateTime');
    });

    test('a scale-7 datetime2 stays the driver type rather than rounding', () {
      expect(field('precise'), 'MssqlDateTimeValue?');
      expect(generate(config()), contains('resolves to 100ns'));
    });

    test('a low-scale time becomes Duration, not DateTime', () {
      expect(field('onlyTime'), 'Duration?');
    });

    test('datetimeoffset always stays the driver type', () {
      expect(field('offset'), 'MssqlDateTimeValue?');
    });

    test('binary becomes Uint8List and pulls in its import', () {
      expect(field('payload'), 'Uint8List?');
      expect(generate(config()), contains("import 'dart:typed_data';"));
    });

    test('a GUID is a String, with the upper-case trap documented', () {
      expect(field('guid'), 'String?');
      expect(generate(config()), contains('upper case'));
    });

    test('the CLR types read as text and are marked read-only', () {
      final spatial = table(
        'Places',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('Shape', 'geography', ordinal: 2, nullable: true),
        ],
      );
      final source = generate(config(), spatial);
      expect(source, contains('final String? shape;'));
      expect(source, contains('isReadOnly: true'));
      expect(source, contains('Read-only'));
    });

    test('the reader, not the emitter, is where an unknown type stops', () {
      for (final type in MssqlType.values) {
        final c = MssqlColumnSchema(
          ordinal: 1,
          name: 'C',
          sqlTypeName: type.name,
          type: type,
          nullable: false,
          isIdentity: false,
          isComputed: false,
          isRowVersion: false,
          hasDefault: false,
          maxLength: 10,
          precision: 18,
          scale: 4,
        );
        final mapped = dartTypeFor(
          table('T', columns: <MssqlColumnSchema>[c]),
          c,
          decimalMode: MssqlDecimalMode.doublePrecision,
        );
        expect(mapped.name, isNotEmpty, reason: type.name);
      }
    });
  });

  group('the binding', () {
    test('carries every flag the runtime needs', () {
      final source = generate(config());
      expect(source, contains("identityColumn: 'Id'"));
      expect(source, contains('isIdentity: true'));
      expect(source, contains('isComputed: true'));
      expect(source, contains('isRowVersion: true'));
      expect(source, contains('hasDefault: true'));
      expect(source, contains("primaryKey: const <String>['Id']"));
      expect(source, contains('decimalMode: MssqlDecimalMode.doublePrecision'));
    });

    test('a table with an identity and no trigger uses OUTPUT INSERTED', () {
      expect(
        generate(config()),
        contains('MssqlInsertStrategy.outputInserted'),
      );
    });

    test('an enabled trigger forces SCOPE_IDENTITY, because of error 334', () {
      final triggered = table(
        'Triggered',
        primaryKey: const <String>['Id'],
        hasEnabledTrigger: true,
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
        ],
      );
      final source = generate(config(), triggered);
      expect(source, contains('MssqlInsertStrategy.scopeIdentity'));
      expect(source, contains('applyIdentity:'));
    });

    test('no identity column means nothing to read back', () {
      final natural = table(
        'Natural',
        primaryKey: const <String>['Code'],
        columns: <MssqlColumnSchema>[
          column('Code', 'varchar', maxLength: 10),
          column('Label', 'nvarchar', ordinal: 2, maxLength: 100),
        ],
      );
      expect(
        generate(config(), natural),
        contains('MssqlInsertStrategy.noKeyReadback'),
      );
    });
  });

  group('keys', () {
    test('a single-column key uses that column\'s own type', () {
      expect(
        generate(config()),
        contains('extends MssqlRepository<OrdersRow, int>'),
      );
    });

    test('a composite key gets its own class and withKeyValues', () {
      final composite = table(
        'Lines',
        primaryKey: const <String>['OrderId', 'LineNo'],
        columns: <MssqlColumnSchema>[
          column('OrderId', 'int'),
          column('LineNo', 'int', ordinal: 2),
        ],
      );
      final source = generate(config(), composite);
      expect(source, contains('class LinesKey {'));
      expect(source, contains('extends MssqlRepository<LinesRow, LinesKey>'));
      expect(source, contains('super.withKeyValues'));
      expect(source, contains('keyValues: (key) => key.toColumns()'));
    });

    test('a table with no key gets Never, so the key methods are unusable', () {
      final keyless = table(
        'NoKey',
        columns: <MssqlColumnSchema>[column('A', 'int')],
      );
      final source = generate(config(), keyless);
      expect(source, contains('MssqlRepository<NoKeyRow, Never>'));
      expect(source, contains('nothing identifies one row'));
    });

    test('a view is keyless too', () {
      final view = table(
        'OpenOrders',
        isView: true,
        columns: <MssqlColumnSchema>[column('Id', 'int')],
      );
      expect(
        generate(config(), view),
        contains('MssqlRepository<OpenOrdersRow, Never>'),
      );
    });
  });

  group('typed columns', () {
    test('each column becomes a typed constant', () {
      final source = generate(config());
      expect(source, contains("static const String table = 'dbo.Orders';"));
      expect(
        source,
        contains('static final MssqlIntColumn id = column\$id(source);'),
      );
      expect(source, contains('MssqlDoubleColumn.of('));
    });

    test('each column also gets a builder, so it can be rebound', () {
      final source = generate(config());
      expect(
        source,
        contains('static MssqlIntColumn column\$id(MssqlSourceRef source) =>'),
      );
      expect(source, contains('const OrdersFields([this._source]);'));
      expect(
        source,
        contains('MssqlSourceRef get source => _source ?? Orders.source;'),
      );
    });
  });

  group('configuration overrides', () {
    test('class_names replaces the derived name everywhere', () {
      final source = generate(
        config(classNames: <String, String>{'dbo.Orders': 'Siparis'}),
      );
      expect(source, contains('class SiparisRowBase {'));
      expect(source, contains('class SiparisRepositoryBase'));
      expect(source, contains('abstract final class Siparis {'));
    });

    test('field_names replaces one field', () {
      final source = generate(
        config(fieldNames: <String, String>{'dbo.Orders.Code': 'siparisKodu'}),
      );
      expect(source, contains('final String siparisKodu;'));
      expect(source, contains("'Code': siparisKodu"));
    });

    test('readonly_columns marks a column the schema would let us write', () {
      final source = generate(
        config(readOnlyColumns: <String>['dbo.Orders.CreatedAt']),
      );
      expect(source, contains('isReadOnly: true'));
      expect(source, contains('Marked read-only'));
    });

    test('a wildcard read-only pattern matches the column in any table', () {
      expect(
        generate(config(readOnlyColumns: <String>['*.CreatedAt'])),
        contains('isReadOnly: true'),
      );
    });
  });

  group('json', () {
    test('is off by default, because a row is not an API contract', () {
      expect(generate(config()), isNot(contains('toJson')));
    });

    test('on, it keys by Dart field name so renames travel together', () {
      final source = generate(config(json: true));
      expect(source, contains('Map<String, Object?> toJson()'));
      expect(source, contains("'createdAt': createdAt.toIso8601String()"));
    });

    test('a hidden column is left out of toJson but stays a field', () {
      final source = generate(
        config(json: true, hiddenColumns: <String>['dbo.Orders.Guid']),
      );
      expect(source, contains('final String? guid;'));
      expect(source, isNot(contains("'guid': guid")));
    });
  });

  group('the scaffold', () {
    test('extends the generated base and says it is yours', () {
      final source = emitScaffold(TablePlan.of(ordersTable, config()));
      expect(source, contains('class OrdersRow extends OrdersRowBase'));
      expect(
        source,
        contains('class OrdersRepository extends OrdersRepositoryBase'),
      );
      expect(source, contains('never rewritten'));
      expect(source, contains('Application queries go here'));
    });

    test('forwards every constructor parameter to the base', () {
      final source = emitScaffold(TablePlan.of(ordersTable, config()));
      expect(source, contains('required super.id'));
      expect(source, contains('super.discount'));
    });
  });

  group('relations', () {
    List<MssqlTableSchema> world() => <MssqlTableSchema>[
      ordersTable,
      table(
        'Customers',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
        ],
      ),
    ];

    String withRelations(MssqlTableSchema t) => emitGenerated(
      TablePlan.of(t, config(), world: world()),
      version: '0.1.0',
    );

    test('a descriptor class is emitted for each side', () {
      final orders = withRelations(ordersTable);
      expect(orders, contains('abstract final class OrdersRel {'));
      expect(orders, contains("name: 'customer'"));
      expect(orders, contains('MssqlRelationKind.belongsTo'));

      final customers = withRelations(world().last);
      expect(customers, contains('abstract final class CustomersRel {'));
      expect(customers, contains('MssqlRelationKind.hasMany'));
    });

    test('the row carries a nullable field and a loaded set', () {
      final source = withRelations(world().last);
      expect(source, contains('final List<OrdersRow>? _orders;'));
      expect(source, contains('final Set<String> _loadedRelations;'));
    });

    test('the getter throws when the relation was not loaded', () {
      final source = withRelations(ordersTable);
      expect(source, contains("if (!_loadedRelations.contains('customer'))"));
      expect(source, contains('MssqlRelationNotLoadedException'));
    });

    test('a to-many getter returns an empty list, a to-one returns null', () {
      expect(
        withRelations(world().last),
        contains('return _orders ?? const []'),
      );
      expect(withRelations(ordersTable), contains('return _customer;'));
    });

    test('the binding tells the runtime how to attach them', () {
      expect(
        withRelations(ordersTable),
        contains(
          'applyRelations: (row, relations) => '
          'row.withRelations(relations)',
        ),
      );
    });

    test('copyWith carries the relations and the loaded set through', () {
      final source = withRelations(world().last);
      expect(source, contains('orders: _orders,'));
      expect(source, contains('loadedRelations: _loadedRelations,'));
    });

    test('the related table is imported through its model file', () {
      final source = withRelations(world().last);
      expect(source, contains("import '../models/orders.dart';"));
      expect(source, isNot(contains("import 'orders.g.dart';")));
    });

    test('without scaffolding it imports the generated file directly', () {
      final source = emitGenerated(
        TablePlan.of(world().last, config(scaffold: false), world: world()),
        version: '0.1.0',
      );
      expect(source, contains("import 'orders.g.dart';"));
      expect(source, isNot(contains("import '../models/")));
    });

    test('a table with no world gets no relations at all', () {
      expect(generate(config()), isNot(contains('OrdersRel')));
      expect(generate(config()), isNot(contains('_loadedRelations')));
    });

    test('the scaffold forwards the relation parameters', () {
      final source = emitScaffold(
        TablePlan.of(world().last, config(), world: world()),
      );
      expect(source, contains('super.orders'));
      expect(source, contains('super.loadedRelations'));
    });
  });

  group('convention columns', () {
    MssqlTableSchema conventional() => table(
      'Records',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[
        column('Id', 'int', isIdentity: true),
        column('DeletedAt', 'datetime2', ordinal: 2, nullable: true, scale: 3),
        column('CreatedAt', 'datetime2', ordinal: 3, nullable: true, scale: 3),
        column('UpdatedAt', 'datetime2', ordinal: 4, nullable: true, scale: 3),
      ],
    );

    MssqlTableSchema snakeCased() => table(
      'Records',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[
        column('Id', 'int', isIdentity: true),
        column('deleted_at', 'datetime2', ordinal: 2, nullable: true, scale: 3),
        column('created_at', 'datetime2', ordinal: 3, nullable: true, scale: 3),
        column('updated_at', 'datetime2', ordinal: 4, nullable: true, scale: 3),
      ],
    );

    MssqlTableSchema plain() => table(
      'Plain',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[
        column('Id', 'int', isIdentity: true),
        column('Name', 'nvarchar', ordinal: 2, maxLength: 100),
      ],
    );

    test('the convention is deleted_at, found without configuration', () {
      final source = generate(config(), snakeCased());
      expect(source, contains("MssqlSoftDelete(column: 'deleted_at')"));
      expect(source, contains("createdColumn: 'created_at'"));
      expect(source, contains("updatedColumn: 'updated_at'"));
    });

    test('and it recognises the same name spelled differently', () {
      final source = generate(config(), conventional());
      expect(source, contains("MssqlSoftDelete(column: 'DeletedAt')"));
      expect(source, contains("createdColumn: 'CreatedAt'"));
    });

    test('a table without such a column simply does not soft-delete', () {
      final source = generate(config(), plain());
      expect(source, isNot(contains('MssqlSoftDelete')));
      expect(source, isNot(contains('MssqlTimestamps(')));
    });

    test('a table can opt out even when it has the column', () {
      final source = generate(
        config(softDeleteColumns: const <String, String?>{'dbo.Records': null}),
        snakeCased(),
      );
      expect(source, isNot(contains('MssqlSoftDelete')));
      expect(source, contains("createdColumn: 'created_at'"));
    });

    test('the whole convention can be switched off', () {
      final source = generate(
        config(conventions: const ConventionsConfig(softDelete: null)),
        snakeCased(),
      );
      expect(source, isNot(contains('MssqlSoftDelete')));
    });

    test('a per-table name beats the convention', () {
      final source = generate(
        config(
          softDeleteColumns: const <String, String?>{
            'dbo.Records': 'updated_at',
          },
        ),
        snakeCased(),
      );
      expect(source, contains("MssqlSoftDelete(column: 'updated_at')"));
      expect(source, isNot(contains("MssqlSoftDelete(column: 'deleted_at')")));
    });

    test(
      'a convention column of the wrong shape is passed over, not an error',
      () {
        final wrongType = table(
          'Records',
          primaryKey: const <String>['Id'],
          columns: <MssqlColumnSchema>[
            column('Id', 'int', isIdentity: true),
            column('deleted_at', 'bit', ordinal: 2, nullable: true),
          ],
        );
        expect(
          generate(config(), wrongType),
          isNot(contains('MssqlSoftDelete')),
        );

        final notNullable = table(
          'Records',
          primaryKey: const <String>['Id'],
          columns: <MssqlColumnSchema>[
            column('Id', 'int', isIdentity: true),
            column('deleted_at', 'datetime2', ordinal: 2, scale: 3),
          ],
        );
        expect(
          generate(config(), notNullable),
          isNot(contains('MssqlSoftDelete')),
        );
      },
    );

    test('a convention name matches across spellings', () {
      for (final name in <String>['DeletedAt', 'DELETED_AT', 'deletedat']) {
        expect(
          ConventionsConfig.matches(name, 'deleted_at'),
          isTrue,
          reason: name,
        );
      }
      expect(ConventionsConfig.matches('RemovedOn', 'deleted_at'), isFalse);
    });

    test('a soft-delete column is emitted with the schema spelling', () {
      final source = generate(
        config(
          softDeleteColumns: const <String, String?>{
            'dbo.Records': 'deletedat',
          },
        ),
        conventional(),
      );
      expect(source, contains("MssqlSoftDelete(column: 'DeletedAt')"));
      expect(source, isNot(contains('deletedat')));
    });

    test('timestamp columns are canonicalized too', () {
      final source = generate(
        config(
          timestampColumns: const <String, TimestampColumnsConfig>{
            'dbo.Records': TimestampColumnsConfig(
              createdColumn: 'createdat',
              updatedColumn: 'UPDATEDAT',
            ),
          },
        ),
        conventional(),
      );
      expect(source, contains("createdColumn: 'CreatedAt'"));
      expect(source, contains("updatedColumn: 'UpdatedAt'"));
      expect(source, isNot(contains('createdat')));
      expect(source, isNot(contains('UPDATEDAT')));
    });

    test('a name that already matches is left alone', () {
      final source = generate(
        config(
          softDeleteColumns: const <String, String?>{
            'dbo.Records': 'DeletedAt',
          },
        ),
        conventional(),
      );
      expect(source, contains("MssqlSoftDelete(column: 'DeletedAt')"));
    });

    test('the binding built for the drift check carries it too', () {
      final plan = TablePlan.of(
        conventional(),
        config(
          softDeleteColumns: const <String, String?>{
            'dbo.Records': 'deletedat',
          },
        ),
      );
      expect(plan.asBinding().softDelete!.column, 'DeletedAt');
    });
  });

  group('collisions', () {
    test('two columns on one Dart name stop the run', () {
      final colliding = table(
        'Bad',
        columns: <MssqlColumnSchema>[
          column('Order_Date', 'int'),
          column('OrderDate', 'int', ordinal: 2),
        ],
      );
      expect(
        () => generate(config(), colliding),
        throwsA(isA<NameCollision>()),
      );
    });
  });

  group('a per-table setting can name its table either way', () {
    for (final key in <String>[
      'dbo.Orders',
      'Orders',
      'DBO.ORDERS',
      'orders',
    ]) {
      test('class_names keyed "$key"', () {
        expect(
          generate(config(classNames: <String, String>{key: 'Siparis'})),
          contains('class SiparisRowBase'),
        );
      });
    }

    test('field_names too, with or without the schema', () {
      expect(
        generate(config(fieldNames: <String, String>{'Orders.Code': 'kod'})),
        contains('final String kod;'),
      );
      expect(
        generate(
          config(fieldNames: <String, String>{'DBO.orders.code': 'kod'}),
        ),
        contains('final String kod;'),
      );
    });

    test('soft_delete_columns too', () {
      expect(
        generate(
          config(softDeleteColumns: <String, String?>{'orders': 'Precise'}),
        ),
        contains("MssqlSoftDelete(column: 'Precise')"),
      );
    });

    test('and opting a table out beats a convention that would find it', () {
      final found = generate(
        config(conventions: const ConventionsConfig(softDelete: 'Precise')),
      );
      expect(found, contains('MssqlSoftDelete'));

      final optedOut = generate(
        config(
          conventions: const ConventionsConfig(softDelete: 'Precise'),
          softDeleteColumns: const <String, String?>{'Orders': null},
        ),
      );
      expect(optedOut, isNot(contains('MssqlSoftDelete')));
    });

    test('a readonly pattern matches whatever case it is written in', () {
      final plain = generate(config());
      final lower = generate(
        config(readOnlyColumns: <String>['dbo.Orders.Code']),
      );
      final upper = generate(
        config(readOnlyColumns: <String>['DBO.ORDERS.CODE']),
      );
      expect(lower, isNot(plain));
      expect(upper, lower);
    });
  });
}

void mainNullableDefault() {
  String classBody(String source, String name) {
    final start = source.indexOf('class $name ');
    expect(start, isNonNegative, reason: 'no class $name in the output');
    final next = source.indexOf('\nclass ', start + 1);
    return source.substring(start, next < 0 ? source.length : next);
  }

  group('a nullable column with a SQL DEFAULT', () {
    late String create;
    setUp(() => create = classBody(generate(config()), 'OrdersRowBaseCreate'));

    test('is a Field on the Create model, not a bare nullable', () {
      expect(create, contains('final Field<String?> note;'));
      expect(create, contains('this.note = const Field.absent()'));
    });

    test('is only written when the caller actually supplied it', () {
      expect(create, contains('if (note.isPresent) {'));
    });

    test('a nullable column without a default stays a plain nullable', () {
      expect(create, contains('final double? discount;'));
      expect(create, isNot(contains('Field<double?> discount')));
    });

    test('a non-null column with a default stays a plain nullable', () {
      expect(create, contains('final DateTime? createdAt;'));
      expect(create, isNot(contains('Field<DateTime?> createdAt')));
    });

    test('a required column is still required', () {
      expect(create, contains('required this.customerId'));
    });
  });
}

