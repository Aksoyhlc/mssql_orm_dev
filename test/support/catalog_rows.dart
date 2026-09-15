import 'fake_connection.dart';

class CatalogRows {
  CatalogRows({
    this.objects = const <Map<String, Object?>>[],
    this.columns = const <Map<String, Object?>>[],
    this.primaryKeys = const <Map<String, Object?>>[],
    this.uniqueKeys = const <Map<String, Object?>>[],
    this.foreignKeys = const <Map<String, Object?>>[],
    this.triggerOwners = const <Map<String, Object?>>[],
  });

  final List<Map<String, Object?>> objects;
  final List<Map<String, Object?>> columns;
  final List<Map<String, Object?>> primaryKeys;
  final List<Map<String, Object?>> uniqueKeys;
  final List<Map<String, Object?>> foreignKeys;
  final List<Map<String, Object?>> triggerOwners;

  FakeConnection get connection => FakeConnection()
    ..replies.addAll(<List<Map<String, Object?>>>[
      objects,
      columns,
      primaryKeys,
      uniqueKeys,
      foreignKeys,
      triggerOwners,
    ]);
}

Map<String, Object?> object(
  int id,
  String name, {
  String schema = 'dbo',
  String type = 'U',
}) => <String, Object?>{
  'object_id': id,
  'name': name,
  'schema_name': schema,
  'type': type,
};

Map<String, Object?> col(
  int objectId,
  int ordinal,
  String name,
  String type, {
  bool nullable = false,
  bool identity = false,
  bool computed = false,
  int hasDefault = 0,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => <String, Object?>{
  'object_id': objectId,
  'column_id': ordinal,
  'name': name,
  'type_name': type,
  'max_length': maxLength,
  'precision': precision,
  'scale': scale,
  'is_nullable': nullable,
  'is_identity': identity,
  'is_computed': computed,
  'has_default': hasDefault,
};

