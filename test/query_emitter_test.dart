import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:mssql_orm_dev/src/describe.dart';
import 'package:mssql_orm_dev/src/naming.dart';
import 'package:mssql_orm_dev/src/query_emitter.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:test/test.dart';

GeneratorConfig config({
  MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
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
  decimalMode: decimalMode,
);

DescribedColumn column(
  String name,
  String type, {
  int ordinal = 1,
  bool nullable = false,
  int scale = 0,
  int precision = 18,
}) => DescribedColumn(
  ordinal: ordinal,
  name: name,
  sqlTypeName: type,
  nullable: nullable,
  maxLength: 0,
  precision: precision,
  scale: scale,
);

DescribedQuery query({
  String name = 'ordersByCustomer',
  String sql = 'SELECT 1;',
  String? procedure,
  QueryShape shape = QueryShape.list,
  Set<String> notNull = const <String>{},
  List<DeclaredParameter> declared = const <DeclaredParameter>[],
  List<DescribedColumn> columns = const <DescribedColumn>[],
  List<DescribedParameter> parameters = const <DescribedParameter>[],
}) => DescribedQuery(
  definition: QueryDefinition(
    name: name,
    sql: sql,
    sourcePath: 'orders.sql',
    procedure: procedure,
    shape: shape,
    notNullColumns: notNull,
    parameters: declared,
  ),
  columns: columns,
  parameters: parameters,
);

String emit(
  List<DescribedQuery> queries, {
  MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
}) => emitQueries(queries, config(decimalMode: decimalMode), version: '0.1.0');

void main() {
  group('the file', () {
    test('says what it is and where it came from', () {
      final source = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[column('Id', 'int')]),
      ]);
      expect(source, contains('GENERATED — do not edit'));
      expect(source, contains('sp_describe_first_result_set'));
      expect(source, contains('mssql_orm_dev 0.1.0'));
      expect(source, contains('orders.sql'));
    });

    test('sits on the generated database as db.reports', () {
      expect(
        emit(<DescribedQuery>[
          query(columns: <DescribedColumn>[column('Id', 'int')]),
        ]),
        contains('class AppDatabaseReports'),
      );
    });

    test('pulls in dart:typed_data only when something needs it', () {
      final withBytes = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[column('Payload', 'varbinary')]),
      ]);
      expect(withBytes, contains("import 'dart:typed_data';"));

      final without = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[column('Id', 'int')]),
      ]);
      expect(without, isNot(contains('dart:typed_data')));
    });
  });

  group('result shapes', () {
    String methodFor(QueryShape shape) => emit(<DescribedQuery>[
      query(
        shape: shape,
        columns: shape == QueryShape.affected
            ? const <DescribedColumn>[]
            : <DescribedColumn>[column('Id', 'int')],
      ),
    ]);

    test('list returns a list and maps every row', () {
      final source = methodFor(QueryShape.list);
      expect(source, contains('Future<List<OrdersByCustomerRow>>'));
      expect(source, contains('.map(OrdersByCustomerRow.fromRow)'));
    });

    test('single throws when nothing came back', () {
      final source = methodFor(QueryShape.single);
      expect(source, contains('Future<OrdersByCustomerRow> '));
      expect(source, contains('throw MssqlRowNotFoundException'));
    });

    test('single_or_null returns null instead', () {
      final source = methodFor(QueryShape.singleOrNull);
      expect(source, contains('Future<OrdersByCustomerRow?>'));
      expect(source, contains('rows.isEmpty ? null :'));
    });

    test('affected returns a count and emits no row class', () {
      final source = methodFor(QueryShape.affected);
      expect(source, contains('Future<int>'));
      expect(source, contains('return _db.session.execute('));
      expect(source, isNot(contains('class OrdersByCustomerRow')));
    });

    test('retry is never unless the file declared read_only', () {
      expect(methodFor(QueryShape.list), contains('MssqlRetryPolicy.never'));
      expect(methodFor(QueryShape.affected), isNot(contains('idempotentRead')));
    });
  });

  group('column types', () {
    String fieldOf(
      DescribedColumn c, {
      MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
    }) {
      final source = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[c]),
      ], decimalMode: decimalMode);
      final match = RegExp(
        r'final ([A-Za-z0-9<>?]+) [a-zA-Z0-9_]+;',
      ).firstMatch(source);
      return match?.group(1) ?? 'MISSING';
    }

    test('the ordinary scalars', () {
      expect(fieldOf(column('C', 'int')), 'int');
      expect(fieldOf(column('C', 'bigint')), 'int');
      expect(fieldOf(column('C', 'bit')), 'bool');
      expect(fieldOf(column('C', 'float')), 'double');
      expect(fieldOf(column('C', 'nvarchar')), 'String');
      expect(fieldOf(column('C', 'varbinary')), 'Uint8List');
      expect(fieldOf(column('C', 'uniqueidentifier')), 'String');
    });

    test('decimal follows the flag, in both directions', () {
      expect(fieldOf(column('C', 'decimal', scale: 4)), 'double');
      expect(
        fieldOf(
          column('C', 'decimal', scale: 4),
          decimalMode: MssqlDecimalMode.text,
        ),
        'String',
      );
    });

    test('a low-scale date is a DateTime; a scale-7 one is not', () {
      expect(fieldOf(column('C', 'datetime2', scale: 3)), 'DateTime');
      expect(fieldOf(column('C', 'datetime2', scale: 7)), 'MssqlDateTimeValue');
      expect(fieldOf(column('C', 'time', scale: 3)), 'Duration');
      expect(
        fieldOf(column('C', 'datetimeoffset', scale: 3)),
        'MssqlDateTimeValue',
      );
    });

    test('nullability follows the server', () {
      expect(fieldOf(column('C', 'int', nullable: true)), 'int?');
      expect(fieldOf(column('C', 'int')), 'int');
    });

    test('notnull overrides it for the columns it names', () {
      final source = emit(<DescribedQuery>[
        query(
          notNull: <String>{'Toplam'},
          columns: <DescribedColumn>[
            column('Toplam', 'int', nullable: true),
            column('Adet', 'int', ordinal: 2, nullable: true),
          ],
        ),
      ]);
      expect(source, contains('final int toplam;'));
      expect(source, contains('final int? adet;'));
    });

    test('the override is matched without regard to case', () {
      final source = emit(<DescribedQuery>[
        query(
          notNull: <String>{'toplam'},
          columns: <DescribedColumn>[column('Toplam', 'int', nullable: true)],
        ),
      ]);
      expect(source, contains('final int toplam;'));
    });
  });

  group('the row class', () {
    test('reads by column name, and camel-cases the field', () {
      final source = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[column('CUSTOMER_NAME', 'nvarchar')]),
      ]);
      expect(source, contains('final String customerName;'));
      expect(source, contains("row.assertOrdinalNames(columnOrder)"));
      expect(source, contains('row.at(0)'));
    });

    test('an unnamed column is refused rather than given an empty field', () {
      expect(
        () => emit(<DescribedQuery>[
          query(columns: <DescribedColumn>[column('', 'int')]),
        ]),
        throwsA(
          isA<QueryFileError>().having(
            (e) => e.message,
            'message',
            contains('alias'),
          ),
        ),
      );
    });

    test('two columns collapsing onto one field name stop the run', () {
      expect(
        () => emit(<DescribedQuery>[
          query(
            columns: <DescribedColumn>[
              column('Order_Date', 'int'),
              column('OrderDate', 'int', ordinal: 2),
            ],
          ),
        ]),
        throwsA(
          isA<NameCollision>()
              .having((e) => e.dartName, 'dartName', 'orderDate')
              .having((e) => e.sqlNames, 'sqlNames', hasLength(2)),
        ),
      );
    });
  });

  group('parameters', () {
    test('are named and required, so two of a type cannot be swapped', () {
      final source = emit(<DescribedQuery>[
        query(
          columns: <DescribedColumn>[column('Id', 'int')],
          parameters: const <DescribedParameter>[
            DescribedParameter(
              name: 'customerId',
              sqlTypeName: 'int',
              nullable: false,
            ),
          ],
        ),
      ]);
      expect(source, contains('required int customerId'));
      expect(source, contains("'customerId': MssqlValue.int32(customerId)"));
    });

    test('a nullable parameter is not required', () {
      final source = emit(<DescribedQuery>[
        query(
          columns: <DescribedColumn>[column('Id', 'int')],
          parameters: const <DescribedParameter>[
            DescribedParameter(
              name: 'note',
              sqlTypeName: 'nvarchar',
              nullable: true,
            ),
          ],
        ),
      ]);
      expect(source, contains('String? note'));
    });

    test('a query with none takes no arguments at all', () {
      final source = emit(<DescribedQuery>[
        query(columns: <DescribedColumn>[column('Id', 'int')]),
      ]);
      expect(source, contains('ordersByCustomer({'));
      expect(source, contains('const <String, Object?>{}'));
    });
  });

  group('the SQL it embeds', () {
    String sqlLiteralOf(String sql) {
      final source = emit(<DescribedQuery>[
        query(sql: sql, columns: <DescribedColumn>[column('Id', 'int')]),
      ]);
      return RegExp(
            r"queryTypedRows\(\s*('(?:\\.|[^'\\])*')",
            dotAll: true,
          ).firstMatch(source)?.group(1) ??
          'MISSING';
    }

    test('newlines are escaped, so the literal stays on one line', () {
      expect(sqlLiteralOf('SELECT 1\nFROM T;'), contains(r'\n'));
      expect(sqlLiteralOf('SELECT 1\nFROM T;'), isNot(contains('\n')));
    });

    test('quotes, backslashes and dollars are escaped', () {
      expect(sqlLiteralOf("WHERE C = 'x'"), contains(r"\'"));
      expect(sqlLiteralOf(r"WHERE C LIKE @p ESCAPE '\'"), contains(r'\\'));
      expect(sqlLiteralOf(r'SELECT $x'), contains(r'\$'));
    });

    test('a procedure is not this emitter\'s to write', () {
      expect(
        () => emit(<DescribedQuery>[
          query(
            name: 'aylikRapor',
            procedure: 'dbo.sp_AylikRapor',
            sql: '',
            declared: const <DeclaredParameter>[
              DeclaredParameter(name: 'yil', sqlTypeName: 'int'),
            ],
            columns: <DescribedColumn>[column('Id', 'int')],
            parameters: const <DescribedParameter>[
              DescribedParameter(
                name: 'yil',
                sqlTypeName: 'int',
                nullable: false,
              ),
            ],
          ),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('sp_AylikRapor'), contains('callProcedure')),
          ),
        ),
      );
    });
  });

  group('several queries', () {
    test('each gets its own row class and method, in one reports class', () {
      final source = emit(<DescribedQuery>[
        query(name: 'first', columns: <DescribedColumn>[column('A', 'int')]),
        query(name: 'second', columns: <DescribedColumn>[column('B', 'int')]),
      ]);
      expect(source, contains('class FirstRow'));
      expect(source, contains('class SecondRow'));
      expect(source, contains('Future<List<FirstRow>> first('));
      expect(source, contains('Future<List<SecondRow>> second('));
      expect(RegExp('class AppDatabaseReports').allMatches(source).length, 1);
    });

    test('an affected query alongside a list one emits only one row class', () {
      final source = emit(<DescribedQuery>[
        query(name: 'reads', columns: <DescribedColumn>[column('A', 'int')]),
        query(name: 'writes', shape: QueryShape.affected),
      ]);
      expect(source, contains('class ReadsRow'));
      expect(source, isNot(contains('class WritesRow')));
    });
  });
}

