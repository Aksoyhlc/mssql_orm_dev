/// Deterministic SQL-to-Dart naming rules.
library;

/// Reserved and built-in words a generated identifier must not collide with.
///
/// Dart's reserved words plus the ones that would shadow something a generated
/// file uses. A collision gets a trailing underscore.
const Set<String> _reserved = <String>{
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default',
  'do', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'for', 'if',
  'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch', 'this',
  'throw', 'true', 'try', 'var', 'void', 'while', 'with',
  'abstract', 'as', 'covariant', 'deferred', 'dynamic', 'export', 'extension',
  'external', 'factory', 'function', 'get', 'implements', 'import', 'interface',
  'late', 'library', 'mixin', 'operator', 'part', 'required', 'set', 'static',
  'typedef', 'await', 'yield',
  // Would shadow members every generated class has.
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
  'copyWith',
  'toColumns',
  'fromRow', 'toJson',
};

/// A SQL identifier as a Dart field name: `ORDER_DATE` becomes `orderDate`.
String fieldName(String sqlName) {
  final parts = _words(sqlName);
  if (parts.isEmpty) return 'field';
  final buffer = StringBuffer(parts.first.toLowerCase());
  for (final part in parts.skip(1)) {
    buffer.write(_capitalize(part));
  }
  return _makeSafe(buffer.toString());
}

/// Equality shortcut for [dartName]: `customerId` becomes `whereCustomerId`.
String whereShortcutName(String dartName) {
  if (dartName.isEmpty) return 'whereField';
  return 'where${dartName[0].toUpperCase()}${dartName.substring(1)}';
}

/// A SQL table name as a Dart class name: `order_lines` becomes `OrderLines`.
///
/// Names are not singularized; exceptions belong in generator configuration.
String className(String sqlName) {
  final parts = _words(sqlName);
  if (parts.isEmpty) return 'Table';
  final buffer = StringBuffer();
  for (final part in parts) {
    buffer.write(_capitalize(part));
  }
  return _makeSafe(buffer.toString(), leadingDigitPrefix: 'T');
}

/// A file name for a table: `OrderLines` becomes `order_lines`.
String sourceFileName(String sqlName) {
  final name = _words(sqlName).map((w) => w.toLowerCase()).join('_');
  final safe = name.replaceAll(_unsafeInFileName, '_');
  // `.` and `..` name directories, and an empty name names nothing.
  if (safe.isEmpty || safe == '.' || safe == '..') return 'table';
  return safe;
}

/// Everything that must not reach a path component.
final RegExp _unsafeInFileName = RegExp(r'[^a-z0-9_]');

List<String> _words(String value) {
  final out = <String>[];
  final buffer = StringBuffer();
  final chars = value.split('');

  void flush() {
    if (buffer.isNotEmpty) {
      out.add(buffer.toString());
      buffer.clear();
    }
  }

  for (var i = 0; i < chars.length; i++) {
    final char = chars[i];
    if (char == '_' || char == ' ' || char == '-' || char == '.') {
      flush();
      continue;
    }
    final previous = i == 0 ? null : chars[i - 1];
    final next = i + 1 < chars.length ? chars[i + 1] : null;

    // Split lower-to-upper transitions and the final capital in acronym runs.
    final afterLower =
        previous != null && _isUpper(char) && !_isUpper(previous);
    final lastOfRun =
        previous != null &&
        _isUpper(previous) &&
        _isUpper(char) &&
        next != null &&
        !_isUpper(next) &&
        _isLetter(next);
    if ((afterLower || lastOfRun) && buffer.isNotEmpty) flush();

    buffer.write(char);
  }
  flush();
  return out;
}

bool _isLetter(String char) => RegExp('[A-Za-z]').hasMatch(char);

bool _isUpper(String char) =>
    char.toUpperCase() == char && char.toLowerCase() != char;

String _capitalize(String word) {
  if (word.isEmpty) return word;
  // Normalize acronym runs before applying camel case.
  final normalized = word.toUpperCase() == word ? word.toLowerCase() : word;
  return normalized[0].toUpperCase() + normalized.substring(1);
}

/// Makes [identifier] a legal, non-colliding Dart name.
String _makeSafe(String identifier, {String leadingDigitPrefix = 'f'}) {
  var out = identifier.replaceAll(RegExp(r'[^A-Za-z0-9_$]'), '');
  if (out.isEmpty) return '${leadingDigitPrefix}unnamed';
  if (RegExp(r'^[0-9]').hasMatch(out)) out = '$leadingDigitPrefix$out';
  if (_reserved.contains(out)) out = '${out}_';
  return out;
}

/// Raised when two SQL names collapse onto one Dart name.
///
/// A generated `orderDate2` would be ambiguous, so the generator stops and asks
/// for an explicit name instead.
class NameCollision implements Exception {
  const NameCollision(this.scope, this.dartName, this.sqlNames);

  final String scope;
  final String dartName;
  final List<String> sqlNames;

  @override
  String toString() =>
      'NameCollision: in $scope, ${sqlNames.join(' and ')} both become '
      '"$dartName". Give one of them an explicit name in the configuration '
      "(field_names or class_names); generating a numbered suffix would leave "
      'nobody able to tell which is which.';
}

/// Checks that [names] are distinct after mapping, or throws [NameCollision].
void checkDistinct(String scope, Map<String, String> sqlToDart) {
  final byDart = <String, List<String>>{};
  sqlToDart.forEach((sql, dart) {
    byDart.putIfAbsent(dart, () => <String>[]).add(sql);
  });
  for (final entry in byDart.entries) {
    if (entry.value.length > 1) {
      throw NameCollision(scope, entry.key, entry.value);
    }
  }
}

/// Escapes a SQL Server name as a Dart string literal.
///
/// This is separate from SQL identifier quoting and is used for every
/// schema-derived string written to generated Dart source.
String dartStringLiteral(String value) {
  final buffer = StringBuffer("'");
  for (final unit in value.codeUnits) {
    switch (unit) {
      case 0x27: // '
        buffer.write(r"\'");
      case 0x5C: // backslash
        buffer.write(r'\\');
      case 0x24: // $ — would start an interpolation
        buffer.write(r'\$');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        buffer.writeCharCode(unit);
    }
  }
  return (buffer..write("'")).toString();
}
