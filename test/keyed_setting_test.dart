import 'package:mssql_orm_dev/src/config.dart';
import 'package:test/test.dart';

KeyedSetting<String> setting(Map<String, String> entries) =>
    KeyedSetting<String>('class_names', entries);

void main() {
  group('looking a table up', () {
    test('by the spelling it was written in', () {
      expect(
        setting(<String, String>{'dbo.Orders': 'Order'})['dbo.Orders'],
        'Order',
      );
    });

    test('written without its schema', () {
      expect(
        setting(<String, String>{'Orders': 'Order'})['dbo.Orders'],
        'Order',
      );
    });

    test('written in another case', () {
      final s = setting(<String, String>{'DBO.ORDERS': 'Order'});
      expect(s['dbo.Orders'], 'Order');
      expect(
        setting(<String, String>{'orders': 'Order'})['dbo.Orders'],
        'Order',
      );
    });

    test('with the whitespace around it ignored', () {
      expect(
        setting(<String, String>{'  dbo.Orders ': 'Order'})['dbo.Orders'],
        'Order',
      );
    });

    test('a different table is still a miss', () {
      final s = setting(<String, String>{'dbo.Orders': 'Order'});
      expect(s['dbo.Customers'], isNull);
      expect(s['sales.OrderLines'], isNull);
    });

    test('the schema is not simply ignored when one was given', () {
      final s = setting(<String, String>{'sales.Orders': 'SalesOrder'});
      expect(s['sales.Orders'], 'SalesOrder');
      expect(s['dbo.Orders'], isNull);
    });
  });

  group('looking a column up', () {
    KeyedSetting<String> columns(Map<String, String> entries) =>
        KeyedSetting<String>('field_names', entries);

    test('by either spelling of its table', () {
      expect(
        columns(<String, String>{
          'dbo.Orders.cust_id': 'customerId',
        })['dbo.Orders.cust_id'],
        'customerId',
      );
      expect(
        columns(<String, String>{
          'Orders.cust_id': 'customerId',
        })['dbo.Orders.cust_id'],
        'customerId',
      );
    });

    test('a column of another table is a miss', () {
      expect(
        columns(<String, String>{
          'dbo.Orders.cust_id': 'x',
        })['dbo.Invoices.cust_id'],
        isNull,
      );
    });
  });

  group('contains', () {
    test('is true for an entry whose value is null', () {
      final s = KeyedSetting<String?>('soft_delete_columns', <String, String?>{
        'dbo.Audit': null,
      });
      expect(s.contains('dbo.Audit'), isTrue);
      expect(s['dbo.Audit'], isNull);
      expect(s.contains('dbo.Orders'), isFalse);
    });

    test('accepts the same spellings a lookup does', () {
      final s = KeyedSetting<String?>('soft_delete_columns', <String, String?>{
        'Audit': null,
      });
      expect(s.contains('dbo.Audit'), isTrue);
    });
  });

  group('what nothing matched', () {
    test('is reported in the spelling it was written', () {
      final s = setting(<String, String>{
        'dbo.Orders': 'Order',
        'DBO.Ordres': 'Typo',
      });
      s['dbo.Orders'];
      expect(s.unmatchedKeys, <String>['DBO.Ordres']);
    });

    test('is empty once every key has answered', () {
      final s = setting(<String, String>{'dbo.Orders': 'Order'});
      s['dbo.Orders'];
      expect(s.unmatchedKeys, isEmpty);
    });

    test('counts a key matched by any spelling as used', () {
      final s = setting(<String, String>{'Orders': 'Order'});
      s['dbo.Orders'];
      expect(s.unmatchedKeys, isEmpty);
    });

    test('a contains() check counts too', () {
      final s = setting(<String, String>{'dbo.Orders': 'Order'});
      s.contains('dbo.Orders');
      expect(s.unmatchedKeys, isEmpty);
    });

    test('is sorted, so a run reports the same order twice', () {
      final s = setting(<String, String>{'zz': 'a', 'aa': 'b', 'mm': 'c'});
      expect(s.unmatchedKeys, <String>['aa', 'mm', 'zz']);
    });
  });

  group('keys and entries', () {
    test('come back in the spelling they were written', () {
      final s = setting(<String, String>{'DBO.Orders': 'Order'});
      expect(s.keys, <String>['DBO.Orders']);
      expect(s.entries.single.key, 'DBO.Orders');
      expect(s.entries.single.value, 'Order');
    });

    test('an empty setting says so', () {
      expect(setting(const <String, String>{}).isEmpty, isTrue);
      expect(setting(<String, String>{'a': 'b'}).isEmpty, isFalse);
    });
  });

  group('matches, the static form the checks use', () {
    test('agrees with a lookup', () {
      expect(KeyedSetting.matches('dbo.Orders', 'dbo.Orders'), isTrue);
      expect(KeyedSetting.matches('Orders', 'dbo.Orders'), isTrue);
      expect(KeyedSetting.matches('DBO.ORDERS', 'dbo.Orders'), isTrue);
      expect(KeyedSetting.matches('dbo.Customers', 'dbo.Orders'), isFalse);
      expect(KeyedSetting.matches('sales.Orders', 'dbo.Orders'), isFalse);
    });
  });
}

