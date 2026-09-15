import 'package:mssql_orm/orm.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/relations.dart';
import 'package:test/test.dart';

import 'support/schemas.dart';

MssqlForeignKeySchema fk(
  String name,
  List<String> columns,
  String target,
  List<String> targetColumns, {
  String schema = 'dbo',
}) => MssqlForeignKeySchema(
  name: name,
  columns: columns,
  referencedSchema: schema,
  referencedTable: target,
  referencedColumns: targetColumns,
);

MssqlTableSchema customers = table(
  'Customers',
  primaryKey: const <String>['Id'],
  columns: <MssqlColumnSchema>[column('Id', 'int', isIdentity: true)],
);

MssqlTableSchema orders = table(
  'Orders',
  primaryKey: const <String>['Id'],
  columns: <MssqlColumnSchema>[
    column('Id', 'int', isIdentity: true),
    column('CustomerId', 'int', ordinal: 2),
  ],
  foreignKeys: <MssqlForeignKeySchema>[
    fk(
      'FK_Orders_Customers',
      const <String>['CustomerId'],
      'Customers',
      const <String>['Id'],
    ),
  ],
);

MssqlTableSchema orderLines = table(
  'OrderLines',
  primaryKey: const <String>['Id'],
  columns: <MssqlColumnSchema>[
    column('Id', 'int', isIdentity: true),
    column('OrderId', 'int', ordinal: 2),
  ],
  foreignKeys: <MssqlForeignKeySchema>[
    fk(
      'FK_Lines_Orders',
      const <String>['OrderId'],
      'Orders',
      const <String>['Id'],
    ),
  ],
);

List<MssqlTableSchema> get world => <MssqlTableSchema>[
  customers,
  orders,
  orderLines,
];

void main() {
  group('detection', () {
    test('a foreign key on this table is a belongsTo', () {
      final plans = relationsFor(orders, world);
      final customer = plans.firstWhere((p) => p.name == 'customer');
      expect(customer.kind, MssqlRelationKind.belongsTo);
      expect(customer.target, 'dbo.Customers');
      expect(customer.localColumns, <String>['CustomerId']);
      expect(customer.foreignColumns, <String>['Id']);
    });

    test('a foreign key pointing here is a hasMany', () {
      final plans = relationsFor(customers, world);
      final many = plans.single;
      expect(many.name, 'orders');
      expect(many.kind, MssqlRelationKind.hasMany);
      expect(many.localColumns, <String>['Id']);
      expect(many.foreignColumns, <String>['CustomerId']);
    });

    test('a table sees both directions', () {
      final plans = relationsFor(orders, world);
      expect(
        plans.map((p) => p.name),
        containsAll(<String>['customer', 'orderLines']),
      );
    });

    test('the Id suffix is dropped from a belongsTo name', () {
      expect(
        relationsFor(orders, world).map((p) => p.name),
        contains('customer'),
      );
    });

    test('a composite foreign key keeps the referenced table name', () {
      final child = table(
        'Child',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int'),
          column('TenantId', 'int', ordinal: 2),
          column('Code', 'varchar', ordinal: 3, maxLength: 10),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          fk(
            'FK',
            const <String>['TenantId', 'Code'],
            'Parents',
            const <String>['TenantId', 'Code'],
          ),
        ],
      );
      final plan = relationsFor(child, <MssqlTableSchema>[child]).single;
      expect(plan.name, 'parents');
      expect(plan.localColumns, <String>['TenantId', 'Code']);
      expect(plan.foreignColumns, <String>['TenantId', 'Code']);
    });

    test('a self-referencing key gives both directions on one table', () {
      final employees = table(
        'Employees',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('ManagerId', 'int', ordinal: 2, nullable: true),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          fk(
            'FK_Self',
            const <String>['ManagerId'],
            'Employees',
            const <String>['Id'],
          ),
        ],
      );
      final plans = relationsFor(employees, <MssqlTableSchema>[employees]);
      expect(plans.map((p) => p.name), <String>['employees', 'manager']);
      expect(plans.map((p) => p.kind), <MssqlRelationKind>[
        MssqlRelationKind.hasMany,
        MssqlRelationKind.belongsTo,
      ]);
    });

    test('a table with no foreign keys either way has no relations', () {
      final alone = table(
        'Alone',
        columns: <MssqlColumnSchema>[column('Id', 'int')],
      );
      expect(relationsFor(alone, <MssqlTableSchema>[alone]), isEmpty);
    });

    test('the order is stable, so regeneration produces no noise', () {
      final a = relationsFor(orders, world).map((p) => p.name).toList();
      final b = relationsFor(orders, world).map((p) => p.name).toList();
      expect(a, b);
      expect(a, List<String>.of(a)..sort());
    });
  });

  group('collisions', () {
    MssqlTableSchema twoAddresses() => table(
      'Orders',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[
        column('Id', 'int'),
        column('ShippingAddressId', 'int', ordinal: 2),
        column('BillingAddressId', 'int', ordinal: 3),
      ],
      foreignKeys: <MssqlForeignKeySchema>[
        fk(
          'FK_Ship',
          const <String>['ShippingAddressId'],
          'Addresses',
          const <String>['Id'],
        ),
        fk(
          'FK_Bill',
          const <String>['BillingAddressId'],
          'Addresses',
          const <String>['Id'],
        ),
      ],
    );

    test('two keys to the same table with distinct names are fine', () {
      final plans = relationsFor(twoAddresses(), <MssqlTableSchema>[
        twoAddresses(),
      ]);
      expect(
        plans.map((p) => p.name),
        containsAll(<String>['billingAddress', 'shippingAddress']),
      );
    });

    test('two keys that do collapse onto one name stop the run', () {
      final colliding = table(
        'Orders',
        columns: <MssqlColumnSchema>[
          column('AddressId', 'int'),
          column('Address2Id', 'int', ordinal: 2),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          fk(
            'A',
            const <String>['AddressId'],
            'Addresses',
            const <String>['Id'],
          ),
          fk(
            'B',
            const <String>['Address2Id'],
            'Addresses',
            const <String>['Id'],
          ),
        ],
      );
      expect(
        () => relationsFor(
          colliding,
          <MssqlTableSchema>[colliding],
          nameOverrides: KeyedSetting<String>(
            'relation_names',
            <String, String>{'dbo.Orders.address2': 'address'},
          ),
        ),
        throwsA(
          isA<RelationNameCollision>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('relations:'), contains('which is which')),
          ),
        ),
      );
    });
  });

  group('hasOne', () {
    MssqlTableSchema profileWith({required bool unique}) => table(
      'Profiles',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[
        column('Id', 'int', isIdentity: true),
        column('UserId', 'int', ordinal: 2),
      ],
      foreignKeys: <MssqlForeignKeySchema>[
        fk(
          'FK_Profile_User',
          const <String>['UserId'],
          'Users',
          const <String>['Id'],
        ),
      ],
      uniqueKeys: unique
          ? const <List<String>>[
              <String>['Id'],
              <String>['UserId'],
            ]
          : const <List<String>>[
              <String>['Id'],
            ],
    );

    MssqlTableSchema userTable() => table(
      'Users',
      primaryKey: const <String>['Id'],
      columns: <MssqlColumnSchema>[column('Id', 'int', isIdentity: true)],
    );

    test('a unique foreign key on the other side makes it hasOne', () {
      final profiles = profileWith(unique: true);
      final plans = relationsFor(userTable(), <MssqlTableSchema>[
        userTable(),
        profiles,
      ]);
      expect(plans.single.name, 'profiles');
      expect(plans.single.kind, MssqlRelationKind.hasOne);
      expect(plans.single.isToOne, isTrue);
    });

    test('without the unique constraint it stays hasMany', () {
      final profiles = profileWith(unique: false);
      final plans = relationsFor(userTable(), <MssqlTableSchema>[
        userTable(),
        profiles,
      ]);
      expect(plans.single.kind, MssqlRelationKind.hasMany);
      expect(plans.single.isToOne, isFalse);
    });

    test('the columns are identical either way', () {
      final one = relationsFor(userTable(), <MssqlTableSchema>[
        userTable(),
        profileWith(unique: true),
      ]).single;
      final many = relationsFor(userTable(), <MssqlTableSchema>[
        userTable(),
        profileWith(unique: false),
      ]).single;
      expect(one.localColumns, many.localColumns);
      expect(one.foreignColumns, many.foreignColumns);
    });

    test('a unique constraint on other columns does not make it hasOne', () {
      final profiles = table(
        'Profiles',
        primaryKey: const <String>['Id'],
        columns: <MssqlColumnSchema>[
          column('Id', 'int', isIdentity: true),
          column('UserId', 'int', ordinal: 2),
          column('Slug', 'varchar', ordinal: 3, maxLength: 40),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          fk('FK', const <String>['UserId'], 'Users', const <String>['Id']),
        ],
        uniqueKeys: const <List<String>>[
          <String>['Id'],
          <String>['Slug'],
        ],
      );
      expect(
        relationsFor(userTable(), <MssqlTableSchema>[
          userTable(),
          profiles,
        ]).single.kind,
        MssqlRelationKind.hasMany,
      );
    });
  });

  group('configuration', () {
    test('a relation can be renamed', () {
      final plans = relationsFor(
        orders,
        world,
        nameOverrides: KeyedSetting<String>('relation_names', <String, String>{
          'dbo.Orders.customer': 'musteri',
        }),
      );
      expect(plans.map((p) => p.name), contains('musteri'));
      expect(plans.map((p) => p.name), isNot(contains('customer')));
    });

    test('a name override that matches nothing stops the run', () {
      expect(
        () => relationsFor(
          orders,
          world,
          nameOverrides: KeyedSetting<String>(
            'relation_names',
            <String, String>{'dbo.Orders.custmoer': 'x'},
          ),
        ),
        throwsA(
          isA<UnknownRelationOverride>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('custmoer'), contains('customer')),
          ),
        ),
      );
    });

    test('an exclusion that matches nothing stops the run too', () {
      expect(
        () => relationsFor(
          orders,
          world,
          excluded: <String>{'dbo.Orders.nosuch'},
        ),
        throwsA(isA<UnknownRelationOverride>()),
      );
    });

    test('an override for another table is ignored, not rejected', () {
      final plans = relationsFor(
        orders,
        world,
        nameOverrides: KeyedSetting<String>('relation_names', <String, String>{
          'dbo.Customers.orders': 'siparisler',
        }),
      );
      expect(plans, isNotEmpty);
    });

    test('a relation can be left out entirely', () {
      final plans = relationsFor(
        orders,
        world,
        excluded: <String>{'dbo.Orders.orderLines'},
      );
      expect(plans.map((p) => p.name), isNot(contains('orderLines')));
      expect(plans.map((p) => p.name), contains('customer'));
    });
  });

  group('what is deliberately absent', () {
    test('a join-table shape is not turned into belongsToMany', () {
      final userRoles = table(
        'UserRoles',
        primaryKey: const <String>['UserId', 'RoleId'],
        columns: <MssqlColumnSchema>[
          column('UserId', 'int'),
          column('RoleId', 'int', ordinal: 2),
        ],
        foreignKeys: <MssqlForeignKeySchema>[
          fk('A', const <String>['UserId'], 'Users', const <String>['Id']),
          fk('B', const <String>['RoleId'], 'Roles', const <String>['Id']),
        ],
      );
      final plans = relationsFor(userRoles, <MssqlTableSchema>[userRoles]);
      expect(
        plans.map((p) => p.kind),
        everyElement(isNot(MssqlRelationKind.hasOne)),
      );
      expect(plans.map((p) => p.name), <String>['role', 'user']);
    });
  });
}

