import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Files another generation pass owns, so a table-only run must not delete
/// them just because they were not in this plan.
///
/// `queries.g.dart` and `procedures.g.dart` are produced from `.sql` files
/// after the table pass.
const Set<String> kOtherPassBasenames = <String>{
  'queries.g.dart',
  'procedures.g.dart',
};

/// The file that records which generated paths this tool owns.
///
/// Stale cleanup deletes only paths listed here.
class GenerationManifest {
  const GenerationManifest({
    required this.generationId,
    required this.files,
    this.scaffolds = const <String, String>{},
  });

  final String generationId;

  /// Basenames inside the generated output directory, posix-spelled.
  final List<String> files;

  /// Path → SHA-256 of the scaffold source the generator *would* write.
  final Map<String, String> scaffolds;

  static const String fileName = '.mssql_orm.json';

  static String pathFor(String outputDirectory) =>
      p.join(outputDirectory, fileName);

  static GenerationManifest? read(String outputDirectory) {
    final file = File(pathFor(outputDirectory));
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final map = Map<String, Object?>.from(decoded);
    final id = map['id'];
    final files = map['files'];
    if (id is! String || files is! List) return null;
    final scaffoldsRaw = map['scaffolds'];
    final scaffolds = <String, String>{};
    if (scaffoldsRaw is Map) {
      for (final entry in scaffoldsRaw.entries) {
        final value = entry.value;
        if (value is String) {
          scaffolds[entry.key.toString()] = value;
        }
      }
    }
    return GenerationManifest(
      generationId: id,
      files: <String>[
        for (final item in files)
          if (item is String && isOwnedFileName(item)) item,
      ],
      scaffolds: scaffolds,
    );
  }

  /// Whether a manifest entry names a file this generator may delete.
  static bool isOwnedFileName(String name) {
    if (name.isEmpty) return false;
    if (name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    if (p.basename(name) != name) return false;
    return true;
  }

  /// Paths that look generated, used only when no manifest exists yet.
  static Set<String> bootstrapOwned(String outputDirectory) {
    final directory = Directory(outputDirectory);
    if (!directory.existsSync()) return <String>{};
    final owned = <String>{};
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == fileName) continue;
      if (kOtherPassBasenames.contains(name)) continue;
      if (name.endsWith('.g.dart') || name == 'generated.dart') {
        owned.add(name);
      }
    }
    return owned;
  }

  String toJsonText() {
    final map = <String, Object?>{
      'id': generationId,
      'files': files,
      if (scaffolds.isNotEmpty) 'scaffolds': scaffolds,
    };
    return '${const JsonEncoder.withIndent('  ').convert(map)}\n';
  }
}

/// SHA-256 of [source], hex. Used for generation ids and scaffold contracts.
String sha256Hex(String source) =>
    sha256.convert(utf8.encode(source)).toString();

/// Stable digest of every owned path and its formatted source.
///
/// Order is sorted so two runs that emit the same files in a different
/// walk order still agree. The manifest's own contents are excluded: they
/// *contain* this digest, so hashing them as well would not terminate.
String generationIdFor(Map<String, String> pathToContent) {
  final names = pathToContent.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final name in names) {
    buffer
      ..write(name)
      ..write('\n')
      ..write(pathToContent[name])
      ..write('\n');
  }
  return sha256Hex(buffer.toString());
}
