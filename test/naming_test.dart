import 'package:mssql_orm_dev/src/naming.dart';
import 'package:test/test.dart';

void main() {
  mainFileNameSafety();
  group('field names', () {
    test('separators and case boundaries both split words', () {
      expect(fieldName('ORDER_DATE'), 'orderDate');
      expect(fieldName('order date'), 'orderDate');
      expect(fieldName('order-date'), 'orderDate');
      expect(fieldName('OrderDate'), 'orderDate');
      expect(fieldName('orderDate'), 'orderDate');
    });

    test('a single word is left as one word', () {
      expect(fieldName('name'), 'name');
      expect(fieldName('Name'), 'name');
      expect(fieldName('CRTDT'), 'crtdt');
    });

    test('a run of capitals stays one word', () {
      expect(fieldName('CustomerID'), 'customerId');
      expect(fieldName('HTTPStatus'), 'httpStatus');
    });

    test('a Dart keyword gets an underscore rather than a rename', () {
      expect(fieldName('default'), 'default_');
      expect(fieldName('class'), 'class_');
      expect(fieldName('is'), 'is_');
    });

    test('a name that would shadow a generated member is escaped too', () {
      expect(fieldName('hashCode'), 'hashCode_');
      expect(fieldName('toColumns'), 'toColumns_');
    });

    test('a leading digit gets a prefix, since Dart forbids one', () {
      expect(fieldName('2024Total'), 'f2024Total');
    });

    test('characters Dart cannot use are dropped', () {
      expect(fieldName(r'Total$#!'), r'total$');
    });
  });

  group('class names', () {
    test('the table name is not singularised', () {
      expect(className('Users'), 'Users');
      expect(className('order_lines'), 'OrderLines');
      expect(className('Kullanicilar'), 'Kullanicilar');
      expect(className('Siparisler'), 'Siparisler');
    });

    test('a leading digit gets a class-shaped prefix', () {
      expect(className('2024Sales'), 'T2024Sales');
    });

    test('an all-capitals name becomes readable', () {
      expect(className('TBLKULLANICI'), 'Tblkullanici');
    });
  });

  group('file names', () {
    test('words become snake_case', () {
      expect(sourceFileName('OrderLines'), 'order_lines');
      expect(sourceFileName('Users'), 'users');
      expect(sourceFileName('ORDER_DATE'), 'order_date');
    });
  });

  group('collisions', () {
    test('two SQL names on one Dart name stop the run', () {
      expect(
        () => checkDistinct('dbo.Orders', <String, String>{
          'Order_Date': 'orderDate',
          'OrderDate': 'orderDate',
        }),
        throwsA(
          isA<NameCollision>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('Order_Date'),
              contains('OrderDate'),
              contains('field_names'),
            ),
          ),
        ),
      );
    });

    test('distinct names pass', () {
      checkDistinct('dbo.Orders', <String, String>{'A': 'a', 'B': 'b'});
    });
  });
}

void mainFileNameSafety() {
  group('sourceFileName is always one path component', () {
    test('the ordinary case is unchanged', () {
      expect(sourceFileName('OrderLines'), 'order_lines');
      expect(sourceFileName('Orders'), 'orders');
    });

    test(
      'a delimited name carrying a separator cannot leave the directory',
      () {
        expect(sourceFileName('reports/2024'), isNot(contains('/')));
        expect(sourceFileName(r'reports\2024'), isNot(contains(r'\')));
        expect(sourceFileName('../../etc/passwd'), isNot(contains('/')));
        expect(sourceFileName('../../etc/passwd'), isNot(contains('..')));
      },
    );

    test('a name that reduces to nothing still has something to write to', () {
      expect(sourceFileName('///'), isNotEmpty);

      expect(sourceFileName('...'), isNot(anyOf('.', '..')));
    });

    test('only lower-case letters, digits and underscores come out', () {
      for (final name in <String>[
        'reports/2024',
        r'a\b',
        'a:b',
        'a*b?',
        'Tablo Adi',
        'a b',
      ]) {
        expect(
          sourceFileName(name),
          matches(RegExp(r'^[a-z0-9_]+$')),
          reason: name,
        );
      }
    });
  });
}

