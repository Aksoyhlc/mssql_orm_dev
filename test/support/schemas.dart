import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';

MssqlColumnSchema column(
  String name,
  String sqlTypeName, {
  int ordinal = 1,
  bool nullable = false,
  bool isIdentity = false,
  bool isComputed = false,
  bool isRowVersion = false,
  bool hasDefault = false,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => MssqlColumnSchema(
  ordinal: ordinal,
  name: name,
  sqlTypeName: sqlTypeName,
  type: mssqlTypeForSqlTypeName(sqlTypeName) ?? MssqlType.varchar,
  nullable: nullable,
  isIdentity: isIdentity,
  isComputed: isComputed,
  isRowVersion: isRowVersion,
  hasDefault: hasDefault,
  maxLength: maxLength,
  precision: precision,
  scale: scale,
);

MssqlTableSchema table(
  String name, {
  String schema = 'dbo',
  bool isView = false,
  required List<MssqlColumnSchema> columns,
  List<String> primaryKey = const <String>[],
  List<MssqlForeignKeySchema> foreignKeys = const <MssqlForeignKeySchema>[],
  bool hasEnabledTrigger = false,
  List<List<String>> uniqueKeys = const <List<String>>[],
}) => MssqlTableSchema(
  schema: schema,
  name: name,
  isView: isView,
  columns: columns,
  primaryKey: primaryKey.isEmpty
      ? null
      : MssqlPrimaryKeySchema(name: 'PK_$name', columns: primaryKey),
  foreignKeys: foreignKeys,
  uniqueKeys: <MssqlUniqueKeySchema>[
    for (var i = 0; i < uniqueKeys.length; i++)
      MssqlUniqueKeySchema(
        name: i == 0 && uniqueKeys[i].join() == primaryKey.join()
            ? 'PK_$name'
            : 'UQ_${name}_$i',
        columns: uniqueKeys[i],
        isPrimaryKey: uniqueKeys[i].join() == primaryKey.join(),
      ),
  ],
  triggers: hasEnabledTrigger
      ? <MssqlTriggerSchema>[
          MssqlTriggerSchema(
            name: 'tr_$name',
            isDisabled: false,
            isInsteadOf: false,
          ),
        ]
      : const <MssqlTriggerSchema>[],
);

MssqlTableSchema get ordersTable => table(
  'Orders',
  primaryKey: const <String>['Id'],
  columns: <MssqlColumnSchema>[
    column('Id', 'int', ordinal: 1, isIdentity: true),
    column('CustomerId', 'int', ordinal: 2),
    column('Code', 'varchar', ordinal: 3, maxLength: 20),
    column('Total', 'decimal', ordinal: 4, precision: 18, scale: 4),
    column(
      'Discount',
      'decimal',
      ordinal: 5,
      nullable: true,
      precision: 9,
      scale: 2,
    ),
    column('CreatedAt', 'datetime2', ordinal: 6, hasDefault: true, scale: 3),
    column(
      'Note',
      'nvarchar',
      ordinal: 15,
      nullable: true,
      hasDefault: true,
      maxLength: 200,
    ),
    column('Precise', 'datetime2', ordinal: 7, nullable: true, scale: 7),
    column('OnlyTime', 'time', ordinal: 8, nullable: true, scale: 3),
    column('Offset', 'datetimeoffset', ordinal: 9, nullable: true, scale: 3),
    column('IsOpen', 'bit', ordinal: 10),
    column('Guid', 'uniqueidentifier', ordinal: 11, nullable: true),
    column('Payload', 'varbinary', ordinal: 12, nullable: true, maxLength: -1),
    column(
      'NetTotal',
      'decimal',
      ordinal: 13,
      nullable: true,
      isComputed: true,
      precision: 18,
      scale: 4,
    ),
    column(
      'Version',
      'timestamp',
      ordinal: 14,
      isRowVersion: true,
      maxLength: 8,
    ),
  ],
  foreignKeys: <MssqlForeignKeySchema>[
    MssqlForeignKeySchema(
      name: 'FK_Orders_Customers',
      columns: const <String>['CustomerId'],
      referencedSchema: 'dbo',
      referencedTable: 'Customers',
      referencedColumns: const <String>['Id'],
    ),
  ],
);

