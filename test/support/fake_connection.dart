import 'package:mssql_native/mssql_native.dart';

class DriverCall {
  const DriverCall(this.member, this.sql, this.parameters, this.named);

  final String member;
  final String sql;
  final Map<String, Object?> parameters;
  final Map<Symbol, Object?> named;

  Object? operator [](String name) => named[Symbol(name)];

  Object? bound(String name) {
    final value = parameters[name];
    return value is MssqlValue ? value.value : value;
  }

  @override
  String toString() => 'DriverCall($member, $sql, $parameters)';
}

List<MssqlRow> driverRows(List<Map<String, Object?>> maps) {
  if (maps.isEmpty) return const <MssqlRow>[];
  final names = maps.first.keys.toList();
  return MssqlResultSet.fromValues(
    columns: <MssqlColumn>[
      for (var i = 0; i < names.length; i++)
        MssqlColumn(
          index: i,
          name: names[i],
          type: MssqlType.varchar,
          nullable: true,
          maxLength: 0,
          precision: 0,
          scale: 0,
          nativeType: 0,
        ),
    ],
    values: <List<Object?>>[
      for (final m in maps) <Object?>[for (final name in names) m[name]],
    ],
    metrics: MssqlResultSetMetrics.empty,
  ).typedRows;
}

MssqlExecutionResult driverResult(List<Map<String, Object?>> maps) {
  if (maps.isEmpty) {
    return const MssqlExecutionResult(
      resultSets: <MssqlResultSet>[],
      affectedRows: 0,
      messages: <MssqlServerMessage>[],
      returnStatus: null,
      outputParameters: <String, Object?>{},
      metrics: MssqlExecutionMetrics.empty,
    );
  }
  final names = maps.first.keys.toList();
  return MssqlExecutionResult(
    resultSets: <MssqlResultSet>[
      MssqlResultSet.fromValues(
        columns: <MssqlColumn>[
          for (var i = 0; i < names.length; i++)
            MssqlColumn(
              index: i,
              name: names[i],
              type: MssqlType.varchar,
              nullable: true,
              maxLength: 0,
              precision: 0,
              scale: 0,
              nativeType: 0,
            ),
        ],
        values: <List<Object?>>[
          for (final m in maps) <Object?>[for (final name in names) m[name]],
        ],
        metrics: MssqlResultSetMetrics.empty,
      ),
    ],
    affectedRows: maps.length,
    messages: const <MssqlServerMessage>[],
    returnStatus: null,
    outputParameters: const <String, Object?>{},
    metrics: MssqlExecutionMetrics.empty,
  );
}

mixin _RecordsCalls {
  final List<DriverCall> calls = <DriverCall>[];

  final List<List<Map<String, Object?>>> replies =
      <List<Map<String, Object?>>>[];

  final List<int> affected = <int>[];

  final List<Object?> failures = <Object?>[];

  int _replyIndex = 0;
  int _affectedIndex = 0;
  int _failureIndex = 0;

  DriverCall get onlyCall {
    if (calls.length != 1) {
      throw StateError('Expected one call, got ${calls.length}: $calls');
    }
    return calls.single;
  }

  List<Map<String, Object?>> nextReply() =>
      _replyIndex < replies.length ? replies[_replyIndex++] : const [];

  int nextAffected() =>
      _affectedIndex < affected.length ? affected[_affectedIndex++] : 1;

  void maybeThrow() {
    if (_failureIndex >= failures.length) return;
    final failure = failures[_failureIndex++];
    if (failure != null) throw failure;
  }

  void record(Invocation invocation) {
    final positional = invocation.positionalArguments;
    final raw = invocation.namedArguments[#parameters];
    calls.add(
      DriverCall(
        _name(invocation.memberName),
        positional.isEmpty ? '' : positional.first.toString(),
        raw is Map<String, Object?> ? raw : const <String, Object?>{},
        invocation.namedArguments,
      ),
    );
  }

  static String _name(Symbol symbol) {
    final text = symbol.toString();
    final open = text.indexOf('"');
    return open < 0 ? text : text.substring(open + 1, text.length - 2);
  }
}

class FakeConnection with _RecordsCalls implements MssqlConnection {
  FakeConnection({
    MssqlDecimalMode decimalMode = MssqlDecimalMode.doublePrecision,
  }) : config = MssqlConnectionConfig(
         host: 'fake',
         database: 'fake',
         username: 'fake',
         password: 'fake',
         decimalMode: decimalMode,
       );

  @override
  final MssqlConnectionConfig config;

  @override
  bool get inTransaction => false;

  @override
  String get currentDatabase => config.database;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final member = _RecordsCalls._name(invocation.memberName);
    switch (member) {
      case 'queryRows':
        record(invocation);
        maybeThrow();
        return Future<List<Map<String, Object?>>>.value(nextReply());
      case 'query':
        record(invocation);
        maybeThrow();
        return Future<MssqlExecutionResult>.value(driverResult(nextReply()));
      case 'queryTypedRows':
        record(invocation);
        maybeThrow();
        return Future<List<MssqlRow>>.value(driverRows(nextReply()));
      case 'execute':
        record(invocation);
        maybeThrow();
        return Future<int>.value(nextAffected());
      case 'close':
        record(invocation);
        return Future<void>.value();
      default:
        throw UnimplementedError(
          'FakeConnection was asked for "$member", which no test has taught it '
          'to answer. Add it deliberately rather than returning null.',
        );
    }
  }
}

