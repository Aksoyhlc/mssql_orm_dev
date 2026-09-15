import 'dart:io';

import 'package:mssql_orm_dev/src/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;

  test('generatorVersion matches pubspec.yaml', () {
    expect(generatorVersion, pubspec['version'].toString());
  });

  test('no CLI carries a version constant of its own', () {
    for (final file in Directory('bin').listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      expect(
        file.readAsStringSync(),
        isNot(contains('const String generatorVersion')),
        reason: file.path,
      );
    }
  });
}

