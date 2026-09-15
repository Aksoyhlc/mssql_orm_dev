import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/generator.dart';
import 'package:path/path.dart' as p;

/// Regenerates `mssql_orm/example/db/{generated,models,extensions}`
/// from the declared sales schema. Not a live SQL Server pass.
Future<void> main() async {
  final exampleRoot = p.normalize(
    p.join(
      p.dirname(p.fromUri(Platform.script)),
      '../../mssql_orm/example',
    ),
  );
  for (final dir in <String>[
    p.join(exampleRoot, 'db/generated'),
    p.join(exampleRoot, 'db/models'),
    p.join(exampleRoot, 'db/extensions'),
    p.join(exampleRoot, 'db/queries'),
    p.join(exampleRoot, 'tool'),
  ]) {
    Directory(dir).createSync(recursive: true);
  }
  final config = GeneratorConfig(
    connection: const MssqlConnectionConfig(
      host: 'example',
      database: 'example',
      username: 'example',
      password: '',
    ),
    output: p.join(exampleRoot, 'db/generated'),
    modelsOutput: p.join(exampleRoot, 'db/models'),
    extensionsOutput: p.join(exampleRoot, 'db/extensions'),
    queriesInput: p.join(exampleRoot, 'db/queries'),
    snapshotPath: p.join(exampleRoot, 'tool/mssql_schema.json'),
    schemas: const <String>{'dbo'},
    scaffold: true,
    connectionConfigured: false,
    classNames: const <String, String>{
      'dbo.Orders': 'Order',
      'dbo.OrderLines': 'OrderLine',
      'dbo.Customers': 'Customer',
      'dbo.Products': 'Product',
      'dbo.Categories': 'Category',
    },
    relationNames: const <String, String>{
      'dbo.Orders.orderLines': 'lines',
      'dbo.Categories.categories': 'children',
    },
    softDeleteColumns: const <String, String?>{
      'dbo.Orders': 'DeletedAt',
      'dbo.Customers': 'DeletedAt',
    },
    timestampColumns: const <String, TimestampColumnsConfig>{
      'dbo.Orders': TimestampColumnsConfig(
        createdColumn: 'CreatedAt',
        updatedColumn: 'UpdatedAt',
      ),
      'dbo.Customers': TimestampColumnsConfig(
        createdColumn: 'CreatedAt',
        updatedColumn: 'UpdatedAt',
      ),
    },
    projections: const <ProjectionConfig>[
      ProjectionConfig(
        name: 'OrderListItem',
        table: 'dbo.Orders',
        fields: <ProjectionFieldConfig>[
          ProjectionFieldConfig(column: 'Id', alias: 'id'),
          ProjectionFieldConfig(column: 'Code', alias: 'code'),
          ProjectionFieldConfig(column: 'Status', alias: 'status'),
          ProjectionFieldConfig(column: 'Total', alias: 'total'),
        ],
      ),
    ],
  );
  final snapshot = MssqlSchemaSnapshot(
    tables: salesTables,
    serverVersion: '11.0.2100.60',
    compatibilityLevel: 110,
    capturedAt: DateTime.utc(2026, 9, 8),
  );
  File(config.snapshotPath).writeAsStringSync('${snapshot.toJsonText()}\n');
  final result = await Generator(
    config,
    version: '0.1.0',
  ).run(tables: salesTables);
  stdout.writeln(
    'wrote ${result.written.length}, scaffolded ${result.scaffolded.length}, '
    'unchanged ${result.unchanged.length}',
  );
  for (final warning in result.warnings) {
    stderr.writeln('warning: $warning');
  }
}

List<MssqlTableSchema> get salesTables => <MssqlTableSchema>[
  _table(
    'Categories',
    columns: <MssqlColumnSchema>[
      _col('Id', 'int', ordinal: 1, isIdentity: true),
      _col('ParentId', 'int', ordinal: 2, nullable: true),
      _col('Name', 'nvarchar', ordinal: 3, maxLength: 200),
    ],
    foreignKeys: <MssqlForeignKeySchema>[
      MssqlForeignKeySchema(
        name: 'FK_Categories_Parent',
        columns: const <String>['ParentId'],
        referencedSchema: 'dbo',
        referencedTable: 'Categories',
        referencedColumns: const <String>['Id'],
      ),
    ],
  ),
  _table(
    'Products',
    columns: <MssqlColumnSchema>[
      _col('Id', 'int', ordinal: 1, isIdentity: true),
      _col('CategoryId', 'int', ordinal: 2),
      _col('Sku', 'nvarchar', ordinal: 3, maxLength: 40),
      _col('Name', 'nvarchar', ordinal: 4, maxLength: 400),
      _col('Price', 'decimal', ordinal: 5, precision: 18, scale: 2),
      _col('Stock', 'int', ordinal: 6),
    ],
    foreignKeys: <MssqlForeignKeySchema>[
      MssqlForeignKeySchema(
        name: 'FK_Products_Categories',
        columns: const <String>['CategoryId'],
        referencedSchema: 'dbo',
        referencedTable: 'Categories',
        referencedColumns: const <String>['Id'],
      ),
    ],
    uniqueKeys: <MssqlUniqueKeySchema>[
      MssqlUniqueKeySchema(
        name: 'UQ_Products_Sku',
        columns: const <String>['Sku'],
        isPrimaryKey: false,
        isConstraint: true,
      ),
    ],
  ),
  _table(
    'Customers',
    columns: <MssqlColumnSchema>[
      _col('Id', 'int', ordinal: 1, isIdentity: true),
      _col('Code', 'nvarchar', ordinal: 2, maxLength: 40),
      _col('Name', 'nvarchar', ordinal: 3, maxLength: 200),
      _col('City', 'nvarchar', ordinal: 4, nullable: true, maxLength: 100),
      _col('IsActive', 'bit', ordinal: 5),
      _col('CreatedAt', 'datetime2', ordinal: 6, hasDefault: true, scale: 7),
      _col('UpdatedAt', 'datetime2', ordinal: 7, nullable: true, scale: 7),
      _col('DeletedAt', 'datetime2', ordinal: 8, nullable: true, scale: 7),
    ],
    uniqueKeys: <MssqlUniqueKeySchema>[
      MssqlUniqueKeySchema(
        name: 'UQ_Customers_Code',
        columns: const <String>['Code'],
        isPrimaryKey: false,
        isConstraint: true,
      ),
    ],
  ),
  _table(
    'Orders',
    columns: <MssqlColumnSchema>[
      _col('Id', 'int', ordinal: 1, isIdentity: true),
      _col('CustomerId', 'int', ordinal: 2),
      _col('Code', 'nvarchar', ordinal: 3, maxLength: 40),
      _col('Status', 'nvarchar', ordinal: 4, maxLength: 20),
      _col('Total', 'decimal', ordinal: 5, precision: 18, scale: 2),
      _col('PlacedAt', 'datetime2', ordinal: 6, scale: 7),
      _col('CreatedAt', 'datetime2', ordinal: 7, hasDefault: true, scale: 7),
      _col('UpdatedAt', 'datetime2', ordinal: 8, nullable: true, scale: 7),
      _col('DeletedAt', 'datetime2', ordinal: 9, nullable: true, scale: 7),
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
    uniqueKeys: <MssqlUniqueKeySchema>[
      MssqlUniqueKeySchema(
        name: 'UQ_Orders_Code',
        columns: const <String>['Code'],
        isPrimaryKey: false,
        isConstraint: true,
      ),
    ],
  ),
  _table(
    'OrderLines',
    columns: <MssqlColumnSchema>[
      _col('Id', 'int', ordinal: 1, isIdentity: true),
      _col('OrderId', 'int', ordinal: 2),
      _col('ProductId', 'int', ordinal: 3),
      _col('Quantity', 'int', ordinal: 4),
      _col('UnitPrice', 'decimal', ordinal: 5, precision: 18, scale: 2),
      _col('LineTotal', 'decimal', ordinal: 6, precision: 18, scale: 2),
    ],
    foreignKeys: <MssqlForeignKeySchema>[
      MssqlForeignKeySchema(
        name: 'FK_OrderLines_Orders',
        columns: const <String>['OrderId'],
        referencedSchema: 'dbo',
        referencedTable: 'Orders',
        referencedColumns: const <String>['Id'],
      ),
      MssqlForeignKeySchema(
        name: 'FK_OrderLines_Products',
        columns: const <String>['ProductId'],
        referencedSchema: 'dbo',
        referencedTable: 'Products',
        referencedColumns: const <String>['Id'],
      ),
    ],
  ),
];

MssqlColumnSchema _col(
  String name,
  String sqlTypeName, {
  required int ordinal,
  bool nullable = false,
  bool isIdentity = false,
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
  isComputed: false,
  isRowVersion: false,
  hasDefault: hasDefault,
  maxLength: maxLength,
  precision: precision,
  scale: scale,
);

MssqlTableSchema _table(
  String name, {
  required List<MssqlColumnSchema> columns,
  List<MssqlForeignKeySchema> foreignKeys = const <MssqlForeignKeySchema>[],
  List<MssqlUniqueKeySchema> uniqueKeys = const <MssqlUniqueKeySchema>[],
}) => MssqlTableSchema(
  schema: 'dbo',
  name: name,
  isView: false,
  columns: columns,
  primaryKey: MssqlPrimaryKeySchema(
    name: 'PK_$name',
    columns: const <String>['Id'],
  ),
  foreignKeys: foreignKeys,
  uniqueKeys: <MssqlUniqueKeySchema>[
    MssqlUniqueKeySchema(
      name: 'PK_$name',
      columns: const <String>['Id'],
      isPrimaryKey: true,
      isConstraint: true,
    ),
    ...uniqueKeys,
  ],
);
