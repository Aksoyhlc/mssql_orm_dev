import 'dart:convert';

/// What publishing one planned path would do to the file that is already
/// there — or would leave it alone.
enum GeneratedFileAction { create, replace, remove, unchanged }

/// One path the generator will create, replace, remove, or leave alone.
///
/// [content] is the exact bytes for [create] and [replace]; empty for
/// [remove]; formatted source for [unchanged].
class PlannedFile {
  const PlannedFile(this.path, this.content, this.action);

  /// Absolute or working-directory path, the same spelling [File] uses.
  final String path;

  /// Formatted source for create/replace/unchanged; empty for remove.
  final String content;

  final GeneratedFileAction action;

  bool get writes =>
      action == GeneratedFileAction.create ||
      action == GeneratedFileAction.replace;

  bool get changesDisk => action != GeneratedFileAction.unchanged;
}

/// Every file one generation would publish, decided before any disk write.
class GenerationPlan {
  const GenerationPlan({
    required this.generationId,
    required this.files,
    required this.warnings,
    this.skippedScaffolds = const <String>[],
  });

  /// Digest of the formatted sources this plan would own.
  final String generationId;

  final List<PlannedFile> files;

  final List<String> warnings;

  /// User-owned scaffold/extension files that already existed and were
  /// therefore not rewritten.
  final List<String> skippedScaffolds;

  bool get changed => files.any((file) => file.changesDisk);

  Iterable<PlannedFile> withAction(GeneratedFileAction action) =>
      files.where((file) => file.action == action);

  /// Machine-readable form of `--report json`.
  Map<String, Object?> toJson({Map<String, String>? diffs}) {
    return <String, Object?>{
      'generationId': generationId,
      'changed': changed,
      'files': <Map<String, Object?>>[
        for (final file in files)
          <String, Object?>{
            'path': file.path,
            'action': file.action.name,
            if (diffs != null &&
                diffs.containsKey(file.path) &&
                file.action != GeneratedFileAction.unchanged)
              'diff': diffs[file.path],
          },
      ],
      'warnings': warnings,
      'skippedScaffolds': skippedScaffolds,
    };
  }

  String toJsonText({Map<String, String>? diffs}) =>
      const JsonEncoder.withIndent('  ').convert(toJson(diffs: diffs));
}

/// A unified diff of [previous] versus [next] for [path].
String unifiedDiff({
  required String path,
  required String? previous,
  required String next,
}) {
  if (previous == next) return '';
  final oldLines = previous == null ? const <String>[] : _splitKeep(previous);
  final newLines = _splitKeep(next);
  final buffer = StringBuffer()
    ..writeln('--- ${previous == null ? '/dev/null' : 'a/$path'}')
    ..writeln('+++ b/$path');
  if (oldLines.isEmpty && newLines.isEmpty) return buffer.toString();

  final hunks = _hunks(oldLines, newLines);
  if (hunks.isEmpty) {
    // Same lines but different endings — report the missing newline.
    buffer.writeln('@@ -0,0 +0,0 @@');
    buffer.writeln('\\ No newline at end of file');
    return buffer.toString();
  }
  for (final hunk in hunks) {
    buffer.write(hunk);
  }
  return buffer.toString();
}

List<String> _splitKeep(String source) {
  if (source.isEmpty) return const <String>[];
  final lines = source.split('\n');
  if (source.endsWith('\n')) {
    return lines.sublist(0, lines.length - 1);
  }
  return lines;
}

/// Context lines on each side of a change.
const int _diffContext = 3;

List<String> _hunks(List<String> oldLines, List<String> newLines) {
  // Large inputs fall back to a coarse diff to avoid O((n+m)²) allocation.
  final edits = oldLines.length + newLines.length > 1500
      ? _coarse(oldLines, newLines)
      : _myers(oldLines, newLines);
  if (edits.isEmpty) return const <String>[];

  final hunks = <String>[];
  var index = 0;
  while (index < edits.length) {
    while (index < edits.length && edits[index].kind == _EditKind.equal) {
      index++;
    }
    if (index >= edits.length) break;

    var start = index;
    var oldStart = 0;
    var newStart = 0;
    for (var i = 0; i < start; i++) {
      if (edits[i].kind != _EditKind.add) oldStart++;
      if (edits[i].kind != _EditKind.remove) newStart++;
    }
    var contextBefore = 0;
    while (contextBefore < _diffContext &&
        start - contextBefore - 1 >= 0 &&
        edits[start - contextBefore - 1].kind == _EditKind.equal) {
      contextBefore++;
    }
    start -= contextBefore;
    oldStart -= contextBefore;
    newStart -= contextBefore;

    var end = index;
    var equals = 0;
    while (end < edits.length) {
      if (edits[end].kind == _EditKind.equal) {
        equals++;
        if (equals > _diffContext * 2) {
          end -= _diffContext;
          break;
        }
      } else {
        equals = 0;
      }
      end++;
    }
    if (equals > _diffContext && end == edits.length) {
      end -= equals - _diffContext;
    }

    var oldCount = 0;
    var newCount = 0;
    final body = StringBuffer();
    for (var i = start; i < end; i++) {
      final edit = edits[i];
      switch (edit.kind) {
        case _EditKind.equal:
          body.writeln(' ${edit.line}');
          oldCount++;
          newCount++;
        case _EditKind.remove:
          body.writeln('-${edit.line}');
          oldCount++;
        case _EditKind.add:
          body.writeln('+${edit.line}');
          newCount++;
      }
    }
    hunks.add(
      '@@ -$oldStart,$oldCount +$newStart,$newCount @@\n${body.toString()}',
    );
    index = end;
  }
  return hunks;
}

enum _EditKind { equal, add, remove }

class _Edit {
  const _Edit(this.kind, this.line);
  final _EditKind kind;
  final String line;
}

/// Line-by-line dump used when Myers would be too expensive.
///
/// It is still a valid unified diff. It is just not a short one.
List<_Edit> _coarse(List<String> a, List<String> b) {
  final edits = <_Edit>[];
  final shared = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < shared && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shared - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  for (var i = 0; i < prefix; i++) {
    edits.add(_Edit(_EditKind.equal, a[i]));
  }
  for (var i = prefix; i < a.length - suffix; i++) {
    edits.add(_Edit(_EditKind.remove, a[i]));
  }
  for (var i = prefix; i < b.length - suffix; i++) {
    edits.add(_Edit(_EditKind.add, b[i]));
  }
  for (var i = a.length - suffix; i < a.length; i++) {
    edits.add(_Edit(_EditKind.equal, a[i]));
  }
  return edits;
}

/// Myers shortest-edit script for computing a unified diff.
List<_Edit> _myers(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return const <_Edit>[];
  if (n == 0) {
    return <_Edit>[for (final line in b) _Edit(_EditKind.add, line)];
  }
  if (m == 0) {
    return <_Edit>[for (final line in a) _Edit(_EditKind.remove, line)];
  }

  final max = n + m;
  final offset = max;
  final v = List<int>.filled(2 * max + 1, 0);
  final trace = <List<int>>[];
  var dFound = 0;
  for (var d = 0; d <= max; d++) {
    final snapshot = List<int>.from(v);
    trace.add(snapshot);
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
        x = v[k + 1 + offset];
      } else {
        x = v[k - 1 + offset] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k + offset] = x;
      if (x >= n && y >= m) {
        dFound = d;
        return _backtrack(a, b, trace, dFound);
      }
    }
  }
  return _backtrack(a, b, trace, max);
}

List<_Edit> _backtrack(
  List<String> a,
  List<String> b,
  List<List<int>> trace,
  int dFound,
) {
  final edits = <_Edit>[];
  var x = a.length;
  var y = b.length;
  final offset = a.length + b.length;
  for (var d = dFound; d >= 0; d--) {
    final v = trace[d];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = v[prevK + offset];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
      edits.add(_Edit(_EditKind.equal, a[x]));
    }
    if (d == 0) break;
    if (x == prevX) {
      y--;
      edits.add(_Edit(_EditKind.add, b[y]));
    } else {
      x--;
      edits.add(_Edit(_EditKind.remove, a[x]));
    }
  }
  return edits.reversed.toList();
}
