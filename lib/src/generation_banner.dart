import 'package:mssql_orm/orm.dart';

/// Shared generated-file header: generator version and API contract.
void writeGenerationBanner(
  StringBuffer out, {
  required String version,
  String? source,
}) {
  out.writeln('// GENERATED — do not edit. Rewritten on every run.');
  out.writeln('//');
  if (source != null) {
    out.writeln('// Source: $source');
  }
  out.writeln('// Generator: mssql_orm_dev $version');
  out.writeln('// API contract: ${MssqlApiVersion.current}');
}
