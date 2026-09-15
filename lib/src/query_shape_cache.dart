import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'describe.dart';
import 'query_file.dart';

/// Described shapes stored next to the schema snapshot.
///
/// Offline generation may reuse a cached describe only when the `.sql`
/// file's source hash still matches. A changed file with leftover
/// metadata is refused rather than typed from a lie.
class QueryShapeCache {
  const QueryShapeCache(this.entries);

  final List<CachedQueryShape> entries;

  static String pathFor(GeneratorConfig config) => p.join(
    p.dirname(config.snapshotPath),
    '${p.basenameWithoutExtension(config.snapshotPath)}.queries.json',
  );

  static QueryShapeCache read(GeneratorConfig config) {
    final file = File(pathFor(config));
    if (!file.existsSync()) return const QueryShapeCache(<CachedQueryShape>[]);
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return const QueryShapeCache(<CachedQueryShape>[]);
    final raw = decoded['queries'];
    if (raw is! List) return const QueryShapeCache(<CachedQueryShape>[]);
    return QueryShapeCache(<CachedQueryShape>[
      for (final item in raw)
        if (item is Map)
          CachedQueryShape.fromJson(Map<String, Object?>.from(item)),
    ]);
  }

  CachedQueryShape? find(String sourcePath) {
    for (final entry in entries) {
      if (entry.sourcePath == sourcePath) return entry;
    }
    return null;
  }

  String toJsonText() {
    final map = <String, Object?>{
      'queries': <Map<String, Object?>>[
        for (final entry in entries) entry.toJson(),
      ],
    };
    return '${const JsonEncoder.withIndent('  ').convert(map)}\n';
  }
}

class CachedQueryShape {
  const CachedQueryShape({
    required this.sourcePath,
    required this.sourceHash,
    required this.columns,
    required this.parameters,
  });

  final String sourcePath;
  final String sourceHash;
  final List<DescribedColumn> columns;
  final List<DescribedParameter> parameters;

  factory CachedQueryShape.fromDescribed(DescribedQuery query) =>
      CachedQueryShape(
        sourcePath: query.definition.sourcePath,
        sourceHash: query.definition.sourceHash,
        columns: query.columns,
        parameters: query.parameters,
      );

  factory CachedQueryShape.fromJson(Map<String, Object?> json) {
    return CachedQueryShape(
      sourcePath: json['path'] as String? ?? '',
      sourceHash: json['hash'] as String? ?? '',
      columns: <DescribedColumn>[
        for (final item in json['columns'] as List? ?? const <Object?>[])
          if (item is Map) _columnFromJson(Map<String, Object?>.from(item)),
      ],
      parameters: <DescribedParameter>[
        for (final item in json['parameters'] as List? ?? const <Object?>[])
          if (item is Map) _parameterFromJson(Map<String, Object?>.from(item)),
      ],
    );
  }

  DescribedQuery toDescribed(QueryDefinition definition) => DescribedQuery(
    definition: definition,
    columns: columns,
    parameters: parameters,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'path': sourcePath,
    'hash': sourceHash,
    'columns': <Map<String, Object?>>[
      for (final column in columns)
        <String, Object?>{
          'ordinal': column.ordinal,
          'name': column.name,
          'sqlTypeName': column.sqlTypeName,
          'nullable': column.nullable,
          'maxLength': column.maxLength,
          'precision': column.precision,
          'scale': column.scale,
        },
    ],
    'parameters': <Map<String, Object?>>[
      for (final parameter in parameters)
        <String, Object?>{
          'name': parameter.name,
          'sqlTypeName': parameter.sqlTypeName,
          'nullable': parameter.nullable,
          'declaration': parameter.declaration,
          'maxLength': parameter.maxLength,
          'precision': parameter.precision,
          'scale': parameter.scale,
        },
    ],
  };
}

DescribedColumn _columnFromJson(Map<String, Object?> json) => DescribedColumn(
  ordinal: json['ordinal'] as int? ?? 0,
  name: json['name'] as String? ?? '',
  sqlTypeName: json['sqlTypeName'] as String? ?? 'varchar',
  nullable: json['nullable'] as bool? ?? true,
  maxLength: json['maxLength'] as int? ?? 0,
  precision: json['precision'] as int? ?? 0,
  scale: json['scale'] as int? ?? 0,
);

DescribedParameter _parameterFromJson(Map<String, Object?> json) =>
    DescribedParameter(
      name: json['name'] as String? ?? '',
      sqlTypeName: json['sqlTypeName'] as String? ?? 'varchar',
      nullable: json['nullable'] as bool? ?? true,
      declaration: json['declaration'] as String?,
      maxLength: json['maxLength'] as int? ?? 0,
      precision: json['precision'] as int? ?? 0,
      scale: json['scale'] as int? ?? 0,
    );
