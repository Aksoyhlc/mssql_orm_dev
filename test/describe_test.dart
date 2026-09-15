import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/describe.dart';
import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:test/test.dart';

import 'support/fake_connection.dart';

QueryDefinition parse(String contents) => parseQueryFile('q.sql', contents);

Map<String, Object?> describedColumn(
  int ordinal,
  String name,
  String type, {
  bool nullable = false,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => <String, Object?>{
  'column_ordinal': ordinal,
  'name': name,
  'system_type_name': type,
  'is_nullable': nullable,
  'max_length': maxLength,
  'precision': precision,
  'scale': scale,
};

Map<String, Object?> describedParameter(
  String name,
  String type, {
  bool nullable = true,
}) => <String, Object?>{
  'name': name,
  'suggested_system_type_name': type,
  'suggested_is_nullable': nullable,
};

void main() {
  group('a manual declaration', () {
    test('never asks the server anything', () async {
      final fake = FakeConnection();
      final result = await QueryDescriber(fake).describe(
        parse('''
-- name: gecici
-- describe: manual
-- column: Id int not null
-- column: Ad nvarchar null
SELECT Id, Ad FROM #temp;
'''),
      );
      expect(fake.calls, isEmpty);
      expect(result.columns.map((c) => c.name), <String>['Id', 'Ad']);
      expect(result.columns.first.nullable, isFalse);
      expect(result.columns.last.nullable, isTrue);
      expect(result.columns.first.ordinal, 1);
      expect(result.columns.last.ordinal, 2);
    });

    test('carries the declared parameters through', () async {
      final result = await QueryDescriber(FakeConnection()).describe(
        parse('''
-- name: q
-- describe: manual
-- param: id int
-- column: A int not null
SELECT 1;
'''),
      );
      expect(result.parameters.single.name, 'id');
      expect(result.parameters.single.sqlTypeName, 'int');
    });
  });

  group('a statement that returns nothing', () {
    test('skips the column describe but still describes parameters', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[describedParameter('id', 'int')]);
      final result = await QueryDescriber(fake).describe(
        parse('''
-- name: q
-- returns: affected
DELETE FROM dbo.T WHERE Id = @id;
'''),
      );
      expect(result.columns, isEmpty);
      expect(result.parameters.single.name, 'id');
      expect(fake.calls, hasLength(1));
      expect(fake.onlyCall.sql, contains('sp_describe_undeclared_parameters'));
    });
  });

  group('describing columns', () {
    Future<DescribedQuery> describe(
      List<Map<String, Object?>> columns, [
      List<Map<String, Object?>>? parameters,
    ]) {
      final fake = FakeConnection()
        ..replies.add(parameters ?? const <Map<String, Object?>>[])
        ..replies.add(columns);
      return QueryDescriber(fake).describe(parse('-- name: q\nSELECT 1;'));
    }

    test('maps every reported field', () async {
      final result = await describe(<Map<String, Object?>>[
        describedColumn(
          1,
          'Total',
          'decimal(18,4)',
          nullable: true,
          maxLength: 9,
          precision: 18,
          scale: 4,
        ),
      ]);
      final column = result.columns.single;
      expect(column.ordinal, 1);
      expect(column.name, 'Total');
      expect(column.sqlTypeName, 'decimal');
      expect(column.nullable, isTrue);
      expect(column.maxLength, 9);
      expect(column.precision, 18);
      expect(column.scale, 4);
    });

    test('a parameterised type name is reduced to its base', () async {
      for (final entry in <String, String>{
        'nvarchar(50)': 'nvarchar',
        'nvarchar(max)': 'nvarchar',
        'decimal(18,4)': 'decimal',
        'int': 'int',
        'datetime2(7)': 'datetime2',
      }.entries) {
        final result = await describe(<Map<String, Object?>>[
          describedColumn(1, 'C', entry.key),
        ]);
        expect(
          result.columns.single.sqlTypeName,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test(
      'the statement travels as a parameter, not as concatenated text',
      () async {
        final fake = FakeConnection()
          ..replies.add(const <Map<String, Object?>>[])
          ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
        await QueryDescriber(fake).describe(parse('-- name: q\nSELECT 1;'));
        final columnCall = fake.calls.last;
        expect(columnCall.sql, contains('@tsql = @tsql'));
        expect(columnCall.bound('tsql'), 'SELECT 1;');
      },
    );

    test('no columns at all is an undescribable query, and says so', () async {
      final fake = FakeConnection();
      await expectLater(
        QueryDescriber(fake).describe(parse('-- name: q\nSELECT 1;')),
        throwsA(
          isA<UndescribableQuery>().having(
            (e) => e.reason,
            'reason',
            contains('returns: affected'),
          ),
        ),
      );
    });
  });

  group('naming the case that applies', () {
    Future<void> expectReason(String sql, Matcher reason) async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..failures.addAll(<Object?>[
          null,
          MssqlException(
            type: MssqlErrorType.querySyntax,
            message: 'the server said something',
          ),
        ]);
      await expectLater(
        QueryDescriber(fake).describe(parse('-- name: q\n$sql')),
        throwsA(
          isA<UndescribableQuery>().having((e) => e.reason, 'reason', reason),
        ),
      );
    }

    test('a temp table', () async {
      await expectReason('SELECT A FROM #t;', contains('temporary table'));
    });

    test('dynamic SQL built from a variable', () async {
      await expectReason(
        "DECLARE @s NVARCHAR(50) = N'SELECT 1'; EXEC(@s);",
        contains('from a variable'),
      );
    });

    test('sp_executesql counts as the same case', () async {
      await expectReason('EXEC sp_executesql @s;', contains('dynamically'));
    });

    test('anything else falls back to a plain statement', () async {
      await expectReason(
        'SELECT * FROM dbo.Missing;',
        contains('single result shape'),
      );
    });

    test('the message names the file and the way out', () async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..failures.addAll(<Object?>[
          null,
          MssqlException(type: MssqlErrorType.querySyntax, message: 'boom'),
        ]);
      try {
        await QueryDescriber(
          fake,
        ).describe(parse('-- name: q\nSELECT A FROM #t;'));
        fail('expected UndescribableQuery');
      } on UndescribableQuery catch (error) {
        expect(error.toString(), contains('q.sql'));
        expect(error.toString(), contains('describe: manual'));
        expect(error.toString(), contains('boom'));
      }
    });
  });

  group('describing parameters', () {
    test('an inferred type is used when the file declares none', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedParameter('@code', 'varchar(20)'),
        ])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      final result = await QueryDescriber(
        fake,
      ).describe(parse('-- name: q\nSELECT 1 WHERE Code = @code;'));
      expect(result.parameters.single.name, 'code');
      expect(result.parameters.single.sqlTypeName, 'varchar');
    });

    test('a declared type overrides the inference', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedParameter('code', 'varchar(20)'),
        ])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      final result = await QueryDescriber(fake).describe(
        parse('-- name: q\n-- param: code nvarchar\nSELECT 1 WHERE C = @code;'),
      );
      expect(result.parameters.single.sqlTypeName, 'nvarchar');
    });

    test(
      'a declared parameter the server never saw is still reported',
      () async {
        final fake = FakeConnection()
          ..replies.add(const <Map<String, Object?>>[])
          ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
        final result = await QueryDescriber(
          fake,
        ).describe(parse('-- name: q\n-- param: hidden int\nSELECT 1;'));
        expect(result.parameters.single.name, 'hidden');
      },
    );

    test('parameters come back in a stable order', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedParameter('zebra', 'int'),
          describedParameter('apple', 'int'),
        ])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      final result = await QueryDescriber(
        fake,
      ).describe(parse('-- name: q\nSELECT 1;'));
      expect(result.parameters.map((p) => p.name), <String>['apple', 'zebra']);
    });

    test(
      'a statement with no undeclared parameters is not a failure',
      () async {
        final fake = FakeConnection()
          ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')])
          ..failures.addAll(<Object?>[
            MssqlException(
              type: MssqlErrorType.querySyntax,
              message: 'no parameters',
            ),
            null,
          ]);
        final result = await QueryDescriber(
          fake,
        ).describe(parse('-- name: q\nSELECT 1;'));
        expect(result.parameters, isEmpty);
        expect(result.columns, hasLength(1));
      },
    );
  });

  group('a stored procedure', () {
    test('is described through a call, with its parameters nulled', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'Id', 'int')]);
      final result = await QueryDescriber(fake).describe(
        parse('''
-- name: rapor
-- procedure: dbo.sp_Report
-- param: yil int
-- param: ay int
'''),
      );
      expect(fake.calls, hasLength(1));
      final asked = fake.calls.first.bound('tsql')! as String;
      expect(asked, startsWith('EXEC [dbo].[sp_Report]'));
      expect(asked, contains('@yil = NULL'));
      expect(asked, contains('@ay = NULL'));
      expect(result.columns.single.name, 'Id');
    });

    test('takes its parameters from the file, not from inference', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'Id', 'int')]);
      final result = await QueryDescriber(fake).describe(
        parse('-- name: r\n-- procedure: dbo.sp_R\n-- param: yil int\n'),
      );
      expect(fake.calls, hasLength(1));
      expect(result.parameters.single.sqlTypeName, 'int');
    });

    test('one with no parameters produces a bare EXEC', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'Id', 'int')]);
      await QueryDescriber(
        fake,
      ).describe(parse('-- name: r\n-- procedure: dbo.sp_R\n'));
      expect(fake.calls.first.bound('tsql'), 'EXEC [dbo].[sp_R]');
    });
  });

  group('the column model', () {
    test('converts to the same shape the schema reader produces', () async {
      const column = DescribedColumn(
        ordinal: 2,
        name: 'Total',
        sqlTypeName: 'decimal',
        nullable: true,
        maxLength: 9,
        precision: 18,
        scale: 4,
      );
      final schema = column.asColumn();
      expect(schema.name, 'Total');
      expect(schema.type, MssqlType.decimal);
      expect(schema.nullable, isTrue);
      expect(schema.scale, 4);
      expect(schema.isIdentity, isFalse);
      expect(schema.isServerGenerated, isFalse);
    });

    test('an unrecognised type falls back to text, as the driver does', () {
      const column = DescribedColumn(
        ordinal: 1,
        name: 'C',
        sqlTypeName: 'geography',
        nullable: true,
        maxLength: 0,
        precision: 0,
        scale: 0,
      );
      expect(column.asColumn().type, MssqlType.varchar);
    });
  });
  group('the column describe declares the statement\'s parameters', () {
    test('an inferred parameter reaches @params', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedParameter('@customerId', 'int'),
        ])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      await QueryDescriber(fake).describe(
        parse('-- name: q\nSELECT A FROM dbo.T WHERE Id = @customerId;'),
      );
      final columnCall = fake.calls.last;
      expect(columnCall.sql, contains('@params = @params'));
      expect(columnCall.bound('params'), '@customerId int');
    });

    test('a declared type is what gets declared', () async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      await QueryDescriber(fake).describe(
        parse(
          '-- name: q\n-- param: code nvarchar(20)\n'
          'SELECT A FROM dbo.T WHERE Code = @code;',
        ),
      );
      expect(fake.calls.last.bound('params'), '@code nvarchar(20)');
    });

    test('several parameters are declared in order', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedParameter('@a', 'int'),
          describedParameter('@b', 'varchar(10)'),
        ])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      await QueryDescriber(fake).describe(
        parse('-- name: q\nSELECT A FROM dbo.T WHERE X = @a OR Y = @b;'),
      );
      expect(fake.calls.last.bound('params'), '@a int, @b varchar(10)');
    });

    test('a statement with no parameters declares nothing', () async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      await QueryDescriber(fake).describe(parse('-- name: q\nSELECT 1;'));
      expect(fake.calls.last.bound('params'), isNull);
    });

    test(
      'a procedure call declares nothing: it has no free variables',
      () async {
        final fake = FakeConnection()
          ..replies.add(<Map<String, Object?>>[
            describedColumn(1, 'Id', 'int'),
          ]);
        await QueryDescriber(fake).describe(
          parse('-- name: r\n-- procedure: dbo.sp_R\n-- param: yil int\n'),
        );
        expect(fake.onlyCall.bound('params'), isNull);
      },
    );
  });

  group('verify', () {
    QueryDefinition manual(String columns) => parse(
      '-- name: q\n-- describe: manual\n$columns\nSELECT Id, Ad FROM dbo.T;',
    );

    test('a manual query is sent to the server after all', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedColumn(1, 'Id', 'int'),
          describedColumn(2, 'Ad', 'nvarchar(50)', nullable: true),
        ]);
      final verified = await QueryDescriber(fake).verify(
        manual('-- column: Id int not null\n-- column: Ad nvarchar null'),
      );
      expect(fake.calls, isNotEmpty);
      expect(verified.drift, isNull);
      expect(verified.unverified, isNull);
    });

    test('a declared column the server no longer reports is drift', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'Id', 'int')]);
      final verified = await QueryDescriber(fake).verify(
        manual('-- column: Id int not null\n-- column: Ad nvarchar null'),
      );
      expect(verified.drift, contains('declares 2 column(s)'));
    });

    test('a renamed column is drift', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedColumn(1, 'Identifier', 'int'),
        ]);
      final verified = await QueryDescriber(
        fake,
      ).verify(manual('-- column: Id int not null'));
      expect(verified.drift, contains('the server calls it "Identifier"'));
    });

    test('a retyped column is drift', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedColumn(1, 'Id', 'bigint'),
        ]);
      final verified = await QueryDescriber(
        fake,
      ).verify(manual('-- column: Id int not null'));
      expect(verified.drift, contains('the server reports bigint'));
    });

    test('a nullability change is drift', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          describedColumn(1, 'Id', 'int', nullable: true),
        ]);
      final verified = await QueryDescriber(
        fake,
      ).verify(manual('-- column: Id int not null'));
      expect(verified.drift, contains('the server reports nullable'));
    });

    test('a query SQL Server genuinely cannot describe is reported unverified, '
        'not passed', () async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..failures.addAll(<Object?>[
          null,
          MssqlException(
            type: MssqlErrorType.querySyntax,
            message: 'Invalid object name #t',
          ),
        ]);
      final verified = await QueryDescriber(fake).verify(
        parse(
          '-- name: q\n-- describe: manual\n-- column: Id int not null\n'
          'SELECT Id FROM #t;',
        ),
      );
      expect(verified.drift, isNull);
      expect(verified.unverified, contains('could not describe'));
      expect(verified.query.columns.single.name, 'Id');
    });

    test('a server-described query keeps going through describe', () async {
      final fake = FakeConnection()
        ..replies.add(const <Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[describedColumn(1, 'A', 'int')]);
      final verified = await QueryDescriber(
        fake,
      ).verify(parse('-- name: q\nSELECT 1;'));
      expect(verified.drift, isNull);
      expect(verified.unverified, isNull);
      expect(verified.query.columns.single.name, 'A');
    });
  });
}

