/// A SQL type as written in a `-- param:` / `-- column:` directive or as
/// `system_type_name` from a describe procedure.
class SqlTypeSpec {
  const SqlTypeSpec({
    required this.baseName,
    required this.declaration,
    this.maxLength = 0,
    this.precision = 0,
    this.scale = 0,
    this.isMax = false,
  });

  /// `nvarchar`, `decimal`, `int`. Never carries `(…)`.
  final String baseName;

  /// The spelling the file or the server used, e.g. `nvarchar(50)`.
  final String declaration;

  /// Character or byte length for string/binary types. 0 means unspecified
  /// or `max`.
  final int maxLength;

  final int precision;
  final int scale;

  /// True for `nvarchar(max)` / `varbinary(max)` / `varchar(max)`.
  final bool isMax;

  /// Parses `int`, `nvarchar(50)`, `nvarchar(max)`, `decimal(18,4)`.
  static SqlTypeSpec parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw FormatException('SQL type is empty.');
    }
    final open = trimmed.indexOf('(');
    if (open < 0) {
      return SqlTypeSpec(
        baseName: trimmed.toLowerCase(),
        declaration: trimmed.toLowerCase(),
      );
    }
    final close = trimmed.lastIndexOf(')');
    if (close < 0 || close < open) {
      throw FormatException('SQL type "$raw" has an unclosed parenthesis.');
    }
    final base = trimmed.substring(0, open).trim().toLowerCase();
    final inside = trimmed.substring(open + 1, close).trim();
    final declaration = '$base($inside)'.toLowerCase();
    if (inside.toLowerCase() == 'max') {
      return SqlTypeSpec(baseName: base, declaration: declaration, isMax: true);
    }
    final parts = [
      for (final part in inside.split(',')) part.trim(),
    ].where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) {
      return SqlTypeSpec(baseName: base, declaration: declaration);
    }
    if (base == 'decimal' || base == 'numeric') {
      final precision = int.tryParse(parts[0]) ?? 0;
      final scale = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      return SqlTypeSpec(
        baseName: base,
        declaration: declaration,
        precision: precision,
        scale: scale,
      );
    }
    if (base == 'datetime2' || base == 'time' || base == 'datetimeoffset') {
      return SqlTypeSpec(
        baseName: base,
        declaration: declaration,
        scale: int.tryParse(parts[0]) ?? 0,
      );
    }
    if (base == 'float') {
      return SqlTypeSpec(
        baseName: base,
        declaration: declaration,
        precision: int.tryParse(parts[0]) ?? 0,
      );
    }
    return SqlTypeSpec(
      baseName: base,
      declaration: declaration,
      maxLength: int.tryParse(parts[0]) ?? 0,
    );
  }
}
