import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'generation_plan.dart';

/// Publishes a [GenerationPlan] through staging, a journal, and rename.
///
/// No OS offers an atomic rename of many files. The journal lets the next run
/// roll back a half-written generation. Staging sits next to the output
/// directory, not inside it, so stale cleanup cannot see partial files and
/// renames stay on the same volume.
class AtomicWriter {
  AtomicWriter({
    required this.outputDirectory,
    this.scaffoldDirectories = const <String>[],
  });

  final String outputDirectory;

  /// Where scaffolds are created, if the configuration creates any.
  /// Scaffolds are user-owned and never replaced, but an interrupted creation
  /// must still be undone during recovery.
  final List<String> scaffoldDirectories;

  String get _parent => p.dirname(outputDirectory);

  String get _staging => p.join(_parent, '.mssql_orm_staging');

  String get _backup => p.join(_parent, '.mssql_orm_backup');

  String get _journal => p.join(_parent, '.mssql_orm_journal.json');

  String get _lock => p.join(_parent, '.mssql_orm_lock');

  /// How long to wait for another generation to finish before giving up.
  static const Duration lockTimeout = Duration(seconds: 60);

  /// Every directory a journal entry may name.
  /// Recovery can delete or copy those paths, so journal entries outside these
  /// roots must be rejected before any recovery action.
  List<String> get _allowedRoots => <String>[
    outputDirectory,
    _staging,
    _backup,
    ...scaffoldDirectories,
  ];

  /// Rolls back a publish that did not finish, if a journal is still there.
  /// Do not call from `--check` or `--dry-run`: recovery writes to disk. The
  /// next real generation recovers before publishing.
  void recoverIfNeeded() {
    final journalFile = File(_journal);
    if (!journalFile.existsSync()) return;
    final journal = _Journal.read(
      journalFile,
      backupDirectory: _backup,
      allowedRoots: _allowedRoots,
    );
    switch (journal.phase) {
      case _Phase.staging:
        // Nothing in the output directory has moved yet. Drop the scratch
        // area and the journal; the previous generation is still consistent.
        _deleteDir(_staging);
        _deleteDir(_backup);
        journalFile.deleteSync();
      case _Phase.publishing:
        _rollback(journal);
        _deleteDir(_staging);
        _deleteDir(_backup);
        journalFile.deleteSync();
      case _Phase.finalizing:
        // Every target already holds the new generation. Finishing cleanup
        // is what this phase is for; rolling back would throw that away.
        _deleteDir(_staging);
        _deleteDir(_backup);
        journalFile.deleteSync();
    }
  }

  /// Writes [plan] to disk, or rolls back if any step fails.
  void publish(GenerationPlan plan) {
    final lock = _acquireLock();
    try {
      _publishLocked(plan);
    } finally {
      _releaseLock(lock);
    }
  }

  /// Takes the output root's generation lock, waiting for a run in progress.
  /// Runs share fixed staging, backup and journal paths. Without this lock, one
  /// run could delete another run's scratch files or recovery backups.
  RandomAccessFile _acquireLock() {
    Directory(_parent).createSync(recursive: true);
    final file = File(_lock);
    final deadline = DateTime.now().add(lockTimeout);
    while (true) {
      try {
        return file.openSync(mode: FileMode.writeOnlyAppend)
          ..lockSync(FileLock.exclusive);
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError(
            'Another generation has held the lock at $_lock for longer than '
            '${lockTimeout.inSeconds}s. If no generator is running, delete '
            'that file and try again.',
          );
        }
        sleep(const Duration(milliseconds: 50));
      }
    }
  }

  void _releaseLock(RandomAccessFile lock) {
    try {
      lock.unlockSync();
    } on FileSystemException {
      // Released with the handle below in any case.
    }
    lock.closeSync();
  }

  void _publishLocked(GenerationPlan plan) {
    recoverIfNeeded();
    final changing = plan.files.where((file) => file.changesDisk).toList();
    if (changing.isEmpty) return;

    _deleteDir(_staging);
    _deleteDir(_backup);
    Directory(_staging).createSync(recursive: true);
    Directory(_backup).createSync(recursive: true);

    final entries = <_JournalEntry>[];
    for (final file in changing) {
      String? staged;
      if (file.writes) {
        staged = p.join(_staging, _stageName(file.path, entries.length));
        File(staged).writeAsStringSync(file.content);
      }
      entries.add(
        _JournalEntry(target: file.path, action: file.action, staged: staged),
      );
    }

    var journal = _Journal(phase: _Phase.staging, entries: entries);
    journal.writeTo(File(_journal));

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.action == GeneratedFileAction.create) continue;
      final target = File(entry.target);
      if (!target.existsSync()) continue;
      final backup = p.join(_backup, _stageName(entry.target, i));
      target.copySync(backup);
      entry.backup = backup;
    }
    journal = _Journal(phase: _Phase.publishing, entries: entries);
    journal.writeTo(File(_journal));

    try {
      for (final entry in entries) {
        _apply(entry);
        entry.applied = true;
      }
    } catch (error) {
      _rollback(journal);
      _deleteDir(_staging);
      _deleteDir(_backup);
      File(_journal).deleteSync();
      throw StateError(
        'Generation failed while publishing and the previous files were '
        'restored. ${error.toString()}',
      );
    }

    journal = _Journal(phase: _Phase.finalizing, entries: entries);
    journal.writeTo(File(_journal));
    _deleteDir(_staging);
    _deleteDir(_backup);
    File(_journal).deleteSync();
  }

  void _apply(_JournalEntry entry) {
    final target = File(entry.target);
    switch (entry.action) {
      case GeneratedFileAction.create:
        target.parent.createSync(recursive: true);
        File(entry.staged!).renameSync(target.path);
      case GeneratedFileAction.replace:
        target.parent.createSync(recursive: true);
        if (target.existsSync()) target.deleteSync();
        File(entry.staged!).renameSync(target.path);
      case GeneratedFileAction.remove:
        if (target.existsSync()) target.deleteSync();
      case GeneratedFileAction.unchanged:
        break;
    }
  }

  void _rollback(_Journal journal) {
    // Restoring every backup is the only way back to the previous consistent
    // tree, since the journal is not rewritten after each apply.
    for (final entry in journal.entries.reversed) {
      final target = File(entry.target);
      switch (entry.action) {
        case GeneratedFileAction.create:
          if (target.existsSync()) target.deleteSync();
        case GeneratedFileAction.replace:
        case GeneratedFileAction.remove:
          final backup = entry.backup;
          if (backup != null && File(backup).existsSync()) {
            if (target.existsSync()) target.deleteSync();
            File(backup).copySync(entry.target);
          } else if (target.existsSync()) {
            // No backup means the target did not exist in the previous
            // generation, so rolling back means removing it.
            target.deleteSync();
          }
        case GeneratedFileAction.unchanged:
          break;
      }
    }
  }

  void _deleteDir(String path) {
    final directory = Directory(path);
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  String _stageName(String path, int index) =>
      '$index-${p.basename(path).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}';
}

enum _Phase { staging, publishing, finalizing }

class _Journal {
  _Journal({required this.phase, required this.entries});

  final _Phase phase;
  final List<_JournalEntry> entries;

  /// Reads the journal, or throws with recovery instructions.
  /// A malformed journal cannot be treated as empty: backups may hold the only
  /// copy of the previous generation, and guessing would risk deleting them.
  static _Journal read(
    File file, {
    required String backupDirectory,
    required List<String> allowedRoots,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } catch (error) {
      throw StateError(_unreadable(file, backupDirectory, error));
    }
    if (decoded is! Map) {
      throw StateError(
        _unreadable(file, backupDirectory, 'it is not a JSON object'),
      );
    }
    final map = Map<String, Object?>.from(decoded);
    final phaseName = map['phase'] as String? ?? 'publishing';
    final phase = _Phase.values.firstWhere(
      (value) => value.name == phaseName,
      orElse: () => _Phase.publishing,
    );
    final raw = map['entries'];
    final entries = <_JournalEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final entry = _JournalEntry.fromJson(Map<String, Object?>.from(item));
        // Paths outside this writer's directories are refused.
        if (!_withinRoots(entry.target, allowedRoots) ||
            !_withinRoots(entry.staged, allowedRoots) ||
            !_withinRoots(entry.backup, allowedRoots)) {
          throw StateError(
            _unreadable(
              file,
              backupDirectory,
              'it names "${entry.target}", which is outside the directories '
              'this generator writes to',
            ),
          );
        }
        entries.add(entry);
      }
    }
    return _Journal(phase: phase, entries: entries);
  }

  /// Whether [path] sits inside one of [roots], symlinks and `..` resolved.
  ///
  /// Null passes: an entry may legitimately have no staged or backup file.
  static bool _withinRoots(String? path, List<String> roots) {
    if (path == null) return true;
    if (path.isEmpty) return false;
    final canonical = p.canonicalize(path);
    for (final root in roots) {
      final canonicalRoot = p.canonicalize(root);
      if (canonical == canonicalRoot) return true;
      if (p.isWithin(canonicalRoot, canonical)) return true;
    }
    return false;
  }

  /// Writes the journal atomically via write-then-rename.
  /// Writing directly would truncate the recovery record before a crash; a
  /// sibling file is renamed into place only after its full content is written.
  void writeTo(File file) {
    final encoded = jsonEncode(<String, Object?>{
      'phase': phase.name,
      'entries': <Map<String, Object?>>[
        for (final entry in entries) entry.toJson(),
      ],
    });
    final staged = File('${file.path}.writing');
    staged.writeAsStringSync(encoded, flush: true);
    staged.renameSync(file.path);
  }

  static String _unreadable(File file, String backupDirectory, Object reason) {
    final backup = Directory(backupDirectory);
    final held = backup.existsSync()
        ? backup.listSync().whereType<File>().length
        : 0;
    return 'The generation journal at ${file.path} cannot be read: '
        '$reason. It records which generated files a previous run was '
        'part-way through replacing, so this run will not guess. '
        '${held == 0 ? 'No backup copies are held, so the generated '
                  'directory is whatever that run left; delete the journal '
                  'and regenerate.' : '$held backup copies are held in '
                  '$backupDirectory. Compare them with the generated '
                  'directory, put back the ones you want, then delete both '
                  'the journal and the backup directory and regenerate.'}';
  }
}

class _JournalEntry {
  _JournalEntry({
    required this.target,
    required this.action,
    this.staged,
    this.backup,
    this.applied = false,
  });

  final String target;
  final GeneratedFileAction action;
  final String? staged;
  String? backup;
  bool applied;

  factory _JournalEntry.fromJson(Map<String, Object?> json) {
    final actionName = json['action'] as String? ?? 'replace';
    return _JournalEntry(
      target: json['target'] as String? ?? '',
      action: GeneratedFileAction.values.firstWhere(
        (value) => value.name == actionName,
        orElse: () => GeneratedFileAction.replace,
      ),
      staged: json['staged'] as String?,
      backup: json['backup'] as String?,
      applied: json['applied'] as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target,
    'action': action.name,
    'staged': staged,
    'backup': backup,
    'applied': applied,
  };
}
