import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';

/// How one SQL column becomes one Dart field: the type, how to read it out of
/// an `MssqlRow`, and whether writing it is possible at all.
class DartFieldType {
  const DartFieldType({
    required this.name,
    required this.readable,
    this.forcedReadOnly = false,
    this.note,
  });

  /// The Dart type without a trailing `?`.
  final String name;

  /// Builds the expression that reads this column out of a row.
  ///
  /// [access] is the raw `row['Name']` expression.
  final String Function(String access, bool nullable) readable;

  /// Set for types the driver can read but not meaningfully write.
  final bool forcedReadOnly;

  /// A sentence for the generated field's doc comment, when the mapping
  /// deserves an explanation.
  final String? note;

  String declared(bool nullable) => nullable ? '$name?' : name;
}

/// The Dart type for [column].
///
/// [decimalMode] must match the connection the generated code will run on.
DartFieldType dartTypeFor(
  MssqlTableSchema table,
  MssqlColumnSchema column, {
  required MssqlDecimalMode decimalMode,
}) {
  if (textOnlySqlTypes.contains(column.sqlTypeName)) {
    // hierarchyid, geometry, geography, sql_variant: read as String, write
    // needs the CLR type itself, so marked read-only.
    return DartFieldType(
      name: 'String',
      readable: _cast('String'),
      forcedReadOnly: true,
      note:
          'Read-only: the driver returns ${column.sqlTypeName} as its canonical '
          'text, and writing one needs the CLR type itself.',
    );
  }

  switch (column.type) {
    case MssqlType.bit:
      return DartFieldType(name: 'bool', readable: _cast('bool'));

    case MssqlType.tinyInt:
    case MssqlType.smallInt:
    case MssqlType.int32:
    case MssqlType.int64:
      return DartFieldType(name: 'int', readable: _numeric('toInt'));

    case MssqlType.real:
    case MssqlType.float64:
      return DartFieldType(name: 'double', readable: _numeric('toDouble'));

    case MssqlType.decimal:
    case MssqlType.numeric:
    case MssqlType.money:
    case MssqlType.smallMoney:
      return switch (decimalMode) {
        MssqlDecimalMode.exact => DartFieldType(
          name: 'MssqlDecimal',
          readable: _cast('MssqlDecimal'),
          note:
              'Exact, generated for MssqlDecimalMode.exact. The connection '
              'must use the same mode.',
        ),
        MssqlDecimalMode.text => DartFieldType(
          name: 'String',
          readable: _cast('String'),
          note:
              'Exact decimal text, generated for MssqlDecimalMode.text. The '
              'connection must use the same mode.',
        ),
        MssqlDecimalMode.doublePrecision => DartFieldType(
          name: 'double',
          readable: _numeric('toDouble'),
          note:
              'Generated for MssqlDecimalMode.doublePrecision, which is lossy '
              'past about 15 significant digits. The connection must use the '
              'same mode.',
        ),
      };

    case MssqlType.char:
    case MssqlType.varchar:
    case MssqlType.nchar:
    case MssqlType.nvarchar:
    case MssqlType.text:
    case MssqlType.ntext:
    case MssqlType.xml:
      return DartFieldType(name: 'String', readable: _cast('String'));

    case MssqlType.uniqueIdentifier:
      return DartFieldType(
        name: 'String',
        readable: _cast('String'),
        note:
            'SQL Server returns a GUID in upper case. Compare with '
            'toLowerCase()/toUpperCase() rather than against a lower-case '
            'literal.',
      );

    case MssqlType.binary:
    case MssqlType.varbinary:
    case MssqlType.image:
      if (column.isRowVersion) {
        return DartFieldType(
          name: 'Uint8List',
          readable: _cast('Uint8List'),
          note: 'A rowversion: written by the server on every change.',
        );
      }
      return DartFieldType(name: 'Uint8List', readable: _cast('Uint8List'));

    case MssqlType.date:
    case MssqlType.smallDateTime:
    case MssqlType.dateTime:
      return DartFieldType(name: 'DateTime', readable: _dateTime());

    case MssqlType.dateTime2:
      // scale 7 is 100ns and DateTime resolves to microseconds, so converting
      // would silently drop precision — the same loss this package refuses for
      // DECIMAL. Above scale 6 the value is left as the driver's own type.
      return column.scale > 6
          ? DartFieldType(
              name: 'MssqlDateTimeValue',
              readable: _cast('MssqlDateTimeValue'),
              note:
                  'datetime2(${column.scale}) resolves to 100ns and DateTime to '
                  'microseconds, so this stays the driver\'s own type. Call '
                  'toDateTime() if the extra digits do not matter.',
            )
          : DartFieldType(name: 'DateTime', readable: _dateTime());

    case MssqlType.time:
      return column.scale > 6
          ? DartFieldType(
              name: 'MssqlDateTimeValue',
              readable: _cast('MssqlDateTimeValue'),
              note:
                  'time(${column.scale}) resolves to 100ns and Duration to '
                  'microseconds, so this stays the driver\'s own type. Call '
                  'toDuration() if the extra digits do not matter.',
            )
          : DartFieldType(
              name: 'Duration',
              readable: _duration(),
              note: 'The offset from the start of the day.',
            );

    case MssqlType.dateTimeOffset:
      return DartFieldType(
        name: 'MssqlDateTimeValue',
        readable: _cast('MssqlDateTimeValue'),
        note:
            'DateTime carries no offset — it is UTC or local — so this stays '
            'the driver\'s own type.',
      );
  }
}

String Function(String, bool) _cast(String type) =>
    (access, nullable) => nullable ? '$access as $type?' : '$access! as $type';

/// SQL Server's numeric widths do not line up with Dart's, and which one the
/// driver hands back can depend on the column, so the read goes through `num`.
String Function(String, bool) _numeric(String method) =>
    (access, nullable) => nullable
    ? '($access as num?)?.$method()'
    : '($access! as num).$method()';

String Function(String, bool) _dateTime() =>
    (access, nullable) => nullable
    ? '($access as MssqlDateTimeValue?)?.toDateTime()'
    : '($access! as MssqlDateTimeValue).toDateTime()';

String Function(String, bool) _duration() =>
    (access, nullable) => nullable
    ? '($access as MssqlDateTimeValue?)?.toDuration()'
    : '($access! as MssqlDateTimeValue).toDuration()';
