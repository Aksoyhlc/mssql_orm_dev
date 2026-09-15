import 'package:mssql_orm_dev/src/query_file.dart';
import 'package:test/test.dart';

QueryDefinition parse(String contents) =>
    parseQueryFile('orders.sql', contents);

void main() {
  group('directives', () {
    test('a name and a body', () {
      final q = parse('''
-- name: ordersByCustomer
SELECT o.Id FROM dbo.Orders AS o WHERE o.CustomerId = @customerId;
''');
      expect(q.name, 'ordersByCustomer');
      expect(q.sql, startsWith('SELECT o.Id'));
      expect(q.shape, QueryShape.list);
      expect(q.isManual, isFalse);
    });

    test('the method name is stated, never taken from the file name', () {
      expect(
        () => parse('SELECT 1;'),
        throwsA(
          isA<QueryFileError>().having(
            (e) => e.message,
            'message',
            contains('renaming the file'),
          ),
        ),
      );
    });

    test('a declared parameter, with and without nullability', () {
      final q = parse('''
-- name: q
-- param: customerId int
-- param: note nvarchar null
SELECT 1;
''');
      expect(q.parameters.map((p) => p.name), <String>['customerId', 'note']);
      expect(q.parameters.first.sqlTypeName, 'int');
      expect(q.parameters.first.nullable, isFalse);
      expect(q.parameters.last.nullable, isTrue);
    });

    test('a leading @ on a parameter is accepted and dropped', () {
      final q = parse('-- name: q\n-- param: @id int\nSELECT 1;');
      expect(q.parameters.single.name, 'id');
    });

    test('every result shape', () {
      for (final entry in <String, QueryShape>{
        'list': QueryShape.list,
        'single': QueryShape.single,
        'single_or_null': QueryShape.singleOrNull,
        'affected': QueryShape.affected,
      }.entries) {
        expect(
          parse('-- name: q\n-- returns: ${entry.key}\nSELECT 1;').shape,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('an unknown result shape is refused', () {
      expect(
        () => parse('-- name: q\n-- returns: many\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });

    test('notnull takes one or several columns', () {
      final q = parse('-- name: q\n-- notnull: Toplam, Adet\nSELECT 1;');
      expect(q.notNullColumns, <String>{'Toplam', 'Adet'});
    });

    test('a procedure is named instead of a body', () {
      final q = parse('''
-- name: aylikRapor
-- procedure: dbo.sp_AylikRapor
-- param: yil int
''');
      expect(q.procedure, 'dbo.sp_AylikRapor');
      expect(q.describeTarget, 'dbo.sp_AylikRapor');
    });

    test('a file with neither SQL nor a procedure is refused', () {
      expect(() => parse('-- name: q\n'), throwsA(isA<QueryFileError>()));
    });

    test('a directive with no value is refused', () {
      expect(
        () => parse('-- name:\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });

    test('two name directives are refused', () {
      expect(
        () => parse('-- name: a\n-- name: b\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });
  });

  group('manual description', () {
    test('columns are declared with their nullability', () {
      final q = parse('''
-- name: gecici
-- describe: manual
-- column: Id int not null
-- column: Ad nvarchar null
SELECT Id, Ad FROM #temp;
''');
      expect(q.isManual, isTrue);
      expect(q.manualColumns, hasLength(2));
      expect(q.manualColumns!.first.nullable, isFalse);
      expect(q.manualColumns!.last.nullable, isTrue);
    });

    test(
      'an unstated nullability means nullable, which is the safer reading',
      () {
        final q = parse(
          '-- name: q\n-- describe: manual\n-- column: Id int\nSELECT 1;',
        );
        expect(q.manualColumns!.single.nullable, isTrue);
      },
    );

    test('manual with no columns is refused', () {
      expect(
        () => parse('-- name: q\n-- describe: manual\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });

    test('columns without manual are refused', () {
      expect(
        () => parse('-- name: q\n-- column: Id int\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });

    test('describe takes only "manual"', () {
      expect(
        () => parse('-- name: q\n-- describe: auto\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
    });

    test('a malformed column is refused', () {
      expect(
        () =>
            parse('-- name: q\n-- describe: manual\n-- column: Id\nSELECT 1;'),
        throwsA(isA<QueryFileError>()),
      );
      expect(
        () => parse(
          '-- name: q\n-- describe: manual\n-- column: Id int maybe\nSELECT 1;',
        ),
        throwsA(isA<QueryFileError>()),
      );
    });
  });

  group('what is not a directive', () {
    test('an ordinary leading comment is ignored', () {
      final q = parse('-- this explains the query\n-- name: q\nSELECT 1;');
      expect(q.name, 'q');
    });

    test('a comment inside the SQL stays in the SQL', () {
      final q = parse('''
-- name: q
SELECT 1;
-- name: notADirective
SELECT 2;
''');
      expect(q.name, 'q');
      expect(q.sql, contains('notADirective'));
    });

    test('an unknown key is treated as prose, not as an error', () {
      final q = parse('-- author: someone\n-- name: q\nSELECT 1;');
      expect(q.name, 'q');
    });
  });
}

