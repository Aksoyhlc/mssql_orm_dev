part of '../emitter.dart';

void _emitProjections(StringBuffer out, TablePlan plan) {
  final specs = plan.config.projections.where(
    (spec) => KeyedSetting.matches(spec.table, plan.table.qualifiedName),
  );
  for (final spec in specs) {
    out.writeln();
    _emitProjectionClass(out, plan, spec);
  }
}

void _emitProjectionClass(
  StringBuffer out,
  TablePlan plan,
  ProjectionConfig spec,
) {
  for (final field in spec.fields) {
    if (field.path != null && field.path!.contains('.')) {
      throw ConfigError(
        'projections.${spec.name} field path "${field.path}" needs a '
        'relation join. Related projection paths are not generated until '
        'include/join exists. Use a root-table column, or drop the path.',
      );
    }
  }

  final resolved = <({FieldPlan field, String alias, bool required})>[];
  final aliases = <String, String>{};
  for (final item in spec.fields) {
    final field = _projectionField(plan, spec, item);
    final alias = item.alias ?? field.dartName;
    final previous = aliases[alias.toLowerCase()];
    if (previous != null) {
      throw ConfigError(
        'projections.${spec.name} has two columns aliased "$alias" '
        '($previous and ${field.column.name}). Give one alias:.',
      );
    }
    aliases[alias.toLowerCase()] = field.column.name;
    resolved.add((field: field, alias: alias, required: item.nonNull));
  }

  out.writeln('/// List-row DTO for ${plan.table.qualifiedName}.');
  out.writeln('///');
  out.writeln('/// A projection, not an entity: no writes and no relations.');
  out.writeln('@immutable');
  out.writeln('class ${spec.name} {');
  out.write('  const ${spec.name}({');
  for (final item in resolved) {
    out.write('required this.${item.alias}, ');
  }
  out.writeln('});');
  out.writeln();
  for (final item in resolved) {
    final type = item.required ? item.field.type.name : item.field.declaredType;
    out.writeln('  final $type ${item.alias};');
  }
  out.writeln();
  out.writeln('  /// Descriptor: columns, aliases, and the row mapper.');
  out.writeln('  static final MssqlProjection<${spec.name}> projection =');
  out.writeln('      MssqlProjection<${spec.name}>(');
  out.writeln('    name: ${dartStringLiteral(spec.name)},');
  out.writeln('    columns: <MssqlProjectionColumn>[');
  for (final item in resolved) {
    out.writeln(
      '      MssqlProjectionColumn('
      '${dartStringLiteral(item.alias)}, '
      '${plan.columnsClass}.${item.field.dartName}, '
      'required: ${item.required}),',
    );
  }
  out.writeln('    ],');
  out.writeln('    map: (row) => ${spec.name}(');
  for (var i = 0; i < resolved.length; i++) {
    final item = resolved[i];
    final type = item.required ? item.field.type.name : item.field.declaredType;
    out.writeln('      ${item.alias}: MssqlProjection.decode<$type>(');
    out.writeln('        row,');
    out.writeln('        $i,');
    out.writeln('        projection: ${dartStringLiteral(spec.name)},');
    out.writeln('        column: ${dartStringLiteral(item.alias)},');
    out.writeln(
      '        expression: ${plan.columnsClass}.${item.field.dartName},',
    );
    if (item.required) out.writeln('        required: true,');
    out.writeln('      ),');
  }
  out.writeln('    ),');
  out.writeln('  );');
  out.writeln('}');
}

FieldPlan _projectionField(
  TablePlan plan,
  ProjectionConfig spec,
  ProjectionFieldConfig item,
) {
  final needle = item.column.toLowerCase();
  for (final field in plan.fields) {
    if (field.dartName.toLowerCase() == needle) return field;
    if (field.column.name.toLowerCase() == needle) return field;
  }
  throw ConfigError(
    'projections.${spec.name} names "${item.column}", which is not a '
    'column of ${plan.table.qualifiedName}.',
  );
}
