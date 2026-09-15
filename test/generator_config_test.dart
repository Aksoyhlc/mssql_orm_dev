import 'dart:io';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm_dev/src/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const String _connection = '''
connection:
  host: localhost
  database: Shop
  user: sa
  password: env:DB_PASSWORD
''';

GeneratorConfig parse(
  String yaml, {
  Map<String, String> environment = const <String, String>{
    'DB_PASSWORD': 'secret',
  },
}) => GeneratorConfig.fromMap(
  loadYaml(yaml) as YamlMap,
  environment: environment,
);

void main() {
  mainStrictConfig();
  group('the connection block', () {
    test('is required', () {
      expect(
        () => parse('output: lib/db\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('"connection" block'),
          ),
        ),
      );
    });

    test('names the missing key rather than failing vaguely', () {
      expect(
        () => parse('connection:\n  host: localhost\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('connection.database is missing'),
          ),
        ),
      );
    });

    test('reads the values through', () {
      final config = parse(_connection);
      expect(config.connection.host, 'localhost');
      expect(config.connection.database, 'Shop');
      expect(config.connection.username, 'sa');
      expect(config.connection.password, 'secret');
    });

    test('defaults the port, and parses one when given', () {
      expect(parse(_connection).connection.port, 1433);
      expect(parse('$_connection  port: 14330\n').connection.port, 14330);
    });
  });

  group('env: values', () {
    test('are read from the environment, not taken literally', () {
      expect(parse(_connection).connection.password, 'secret');
    });

    test('an unset variable stops the run instead of connecting as ""', () {
      expect(
        () => parse(_connection, environment: const <String, String>{}),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('DB_PASSWORD'), contains('is not set')),
          ),
        ),
      );
    });

    test('an empty variable counts as unset', () {
      expect(
        () => parse(
          _connection,
          environment: const <String, String>{'DB_PASSWORD': ''},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('work for the host and database too, not just the password', () {
      final config = parse(
        '''
connection:
  host: env:DB_HOST
  database: env:DB_NAME
  user: sa
  password: env:DB_PASSWORD
''',
        environment: const <String, String>{
          'DB_HOST': 'sql.internal',
          'DB_NAME': 'Prod',
          'DB_PASSWORD': 'secret',
        },
      );
      expect(config.connection.host, 'sql.internal');
      expect(config.connection.database, 'Prod');
    });
  });

  group('a literal password', () {
    test('is warned about but does not stop the run', () {
      final config = parse('''
connection:
  host: localhost
  database: Shop
  user: sa
  password: Passw0rd!
''');
      expect(config.connection.password, 'Passw0rd!');
      expect(config.warnings, hasLength(1));
      expect(config.warnings.single, contains('env:NAME'));
    });

    test('an env: password produces no warning', () {
      expect(parse(_connection).warnings, isEmpty);
    });

    test('a literal host is not warned about', () {
      expect(parse(_connection).warnings, isEmpty);
    });
  });

  group('defaults', () {
    test('cover every path and flag, so a minimal file works', () {
      final config = parse(_connection);
      expect(config.output, p.join('.', 'lib/db/generated'));
      expect(config.modelsOutput, p.join('.', 'lib/db/models'));
      expect(config.queriesInput, p.join('.', 'lib/db/queries'));
      expect(config.schemas, <String>{'dbo'});
      expect(config.scaffold, isTrue);
      expect(config.includeViews, isTrue);
      expect(config.include, <String>['*']);
      expect(config.exclude, <String>['sysdiagrams']);
      expect(config.decimalMode, MssqlDecimalMode.exact);
      expect(config.json, isFalse);
    });

    test('are all overridable', () {
      final config = parse('''
$_connection
output: gen
models_output: models
queries_input: sql
schemas: [dbo, sales]
scaffold: false
include_views: false
include: ['Order*']
exclude: [Temp]
decimal_mode: text
json: true
''');
      expect(config.output, p.join('.', 'gen'));
      expect(config.modelsOutput, p.join('.', 'models'));
      expect(config.queriesInput, p.join('.', 'sql'));
      expect(config.schemas, <String>{'dbo', 'sales'});
      expect(config.scaffold, isFalse);
      expect(config.includeViews, isFalse);
      expect(config.include, <String>['Order*']);
      expect(config.exclude, <String>['Temp']);
      expect(config.decimalMode, MssqlDecimalMode.text);
      expect(config.json, isTrue);
    });

    test('decimal_mode reaches the connection as well as the emitter', () {
      final config = parse('$_connection\ndecimal_mode: text\n');
      expect(config.connection.decimalMode, MssqlDecimalMode.text);
    });

    test('a single value where a list is expected is accepted', () {
      expect(parse('$_connection\nschemas: dbo\n').schemas, <String>{'dbo'});
    });
  });

  group('conventions', () {
    test('default to the Eloquent names', () {
      final c = parse(_connection).conventions;
      expect(c.softDelete, 'deleted_at');
      expect(c.createdAt, 'created_at');
      expect(c.updatedAt, 'updated_at');
    });

    test('can be renamed', () {
      final c = parse('''
$_connection
conventions:
  soft_delete: SilindiMi
  created_at: OlusturmaTarihi
''').conventions;
      expect(c.softDelete, 'SilindiMi');
      expect(c.createdAt, 'OlusturmaTarihi');
      expect(c.updatedAt, 'updated_at');
    });

    test('can be switched off, so no table gets one it did not ask for', () {
      expect(
        parse(
          '$_connection\nconventions:\n  soft_delete: false\n',
        ).conventions.softDelete,
        isNull,
      );
      expect(
        parse(
          '$_connection\nconventions:\n  soft_delete: none\n',
        ).conventions.softDelete,
        isNull,
      );
    });

    test('a non-mapping is refused', () {
      expect(
        () => parse('$_connection\nconventions: deleted_at\n'),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('ConventionsConfig.matches', () {
    test('an exact name matches', () {
      expect(ConventionsConfig.matches('deleted_at', 'deleted_at'), isTrue);
    });

    test('case and underscores are set aside', () {
      for (final spelling in <String>[
        'DeletedAt',
        'DELETED_AT',
        'deletedat',
        'Deleted_At',
        'deleted at',
      ]) {
        expect(
          ConventionsConfig.matches(spelling, 'deleted_at'),
          isTrue,
          reason: spelling,
        );
      }
    });

    test('a different column does not match', () {
      expect(ConventionsConfig.matches('deleted_by', 'deleted_at'), isFalse);
      expect(ConventionsConfig.matches('undeleted_at', 'deleted_at'), isFalse);
      expect(ConventionsConfig.matches('created_at', 'deleted_at'), isFalse);
    });

    test('it works the same way for a renamed convention', () {
      expect(ConventionsConfig.matches('SILINDI_MI', 'SilindiMi'), isTrue);
    });
  });

  group('per-table settings', () {
    test('a soft-delete column can be given for one table', () {
      final config = parse('''
$_connection
soft_delete_columns:
  dbo.Orders: SilindiTarih
''');
      expect(config.softDeleteColumns['dbo.Orders'], 'SilindiTarih');
    });

    test('false opts a table out of a convention that would find it', () {
      final config = parse('''
$_connection
soft_delete_columns:
  dbo.Audit: false
''');
      expect(config.softDeleteColumns.contains('dbo.Audit'), isTrue);
      expect(config.softDeleteColumns['dbo.Audit'], isNull);
    });

    test('a non-mapping is refused by name', () {
      expect(
        () => parse('$_connection\nsoft_delete_columns: deleted_at\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('soft_delete_columns'),
          ),
        ),
      );
    });

    test('timestamps take either column, or both', () {
      final config = parse('''
$_connection
timestamps:
  dbo.Orders:
    created: OlusturmaTarihi
    updated: GuncellemeTarihi
  dbo.Logs:
    created: Zaman
''');
      expect(
        config.timestampColumns['dbo.Orders']!.createdColumn,
        'OlusturmaTarihi',
      );
      expect(
        config.timestampColumns['dbo.Orders']!.updatedColumn,
        'GuncellemeTarihi',
      );
      expect(config.timestampColumns['dbo.Logs']!.updatedColumn, isNull);
    });

    test('a timestamps entry naming neither column is refused', () {
      expect(
        () => parse('$_connection\ntimestamps:\n  dbo.Orders:\n    other: x\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('created and/or updated'),
          ),
        ),
      );
    });

    test('name overrides and relation settings are read through', () {
      final config = parse('''
$_connection
class_names:
  dbo.tbl_Orders: Order
field_names:
  dbo.Orders.cust_id: customerId
readonly_columns: ['*.RowVersion']
hidden_columns: ['dbo.Users.PasswordHash']
relation_names:
  dbo.Orders.customer: buyer
exclude_relations: ['dbo.Orders.auditTrail']
''');
      expect(config.classNames['dbo.tbl_Orders'], 'Order');
      expect(config.fieldNames['dbo.Orders.cust_id'], 'customerId');
      expect(config.readOnlyColumns, <String>['*.RowVersion']);
      expect(config.hiddenColumns, <String>['dbo.Users.PasswordHash']);
      expect(config.relationNames['dbo.Orders.customer'], 'buyer');
      expect(config.excludedRelations, <String>['dbo.Orders.auditTrail']);
    });
  });

  group('load', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('mssql_orm_config'));
    tearDown(() => root.deleteSync(recursive: true));

    String write(String yaml, {String name = 'mssql_orm.yaml'}) {
      final path = p.join(root.path, name);
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(yaml);
      return path;
    }

    test('a missing file names the path it looked for', () {
      expect(
        () => GeneratorConfig.load(p.join(root.path, 'absent.yaml')),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('absent.yaml'),
          ),
        ),
      );
    });

    test('a file that is not a mapping is refused', () {
      final path = write('- one\n- two\n');
      expect(
        () => GeneratorConfig.load(path),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('YAML mapping'),
          ),
        ),
      );
    });

    test('reads the file and the environment given to it', () {
      final path = write(_connection);
      final config = GeneratorConfig.load(
        path,
        environment: const <String, String>{'DB_PASSWORD': 'from-env'},
      );
      expect(config.connection.password, 'from-env');
    });

    test('output paths resolve against the working directory, not the '
        'config file', () {
      final path = write(
        '$_connection\noutput: lib/db/generated\n',
        name: p.join('tool', 'mssql_orm.yaml'),
      );
      final config = GeneratorConfig.load(
        path,
        environment: const <String, String>{'DB_PASSWORD': 'x'},
      );
      expect(config.output, p.join('.', 'lib/db/generated'));
      expect(config.output, isNot(contains('tool')));
    });
  });

  group('connection: from', () {
    const String string =
        'Server=db.internal,14330;Database=Shop;User Id=sa;Password=secret';

    test('reads a whole .NET connection string', () {
      final config = parse(
        'connection:\n  from: env:MSSQL_CONNECTION_STRING\n',
        environment: const <String, String>{'MSSQL_CONNECTION_STRING': string},
      );
      expect(config.connection.host, 'db.internal');
      expect(config.connection.port, 14330);
      expect(config.connection.database, 'Shop');
      expect(config.connection.username, 'sa');
      expect(config.connection.password, 'secret');
    });

    test('the rest of the file still applies', () {
      final config = parse(
        'connection:\n'
        '  from: env:CS\n'
        'output: gen\n'
        'schemas: [dbo, sales]\n'
        'decimal_mode: text\n',
        environment: const <String, String>{'CS': string},
      );
      expect(config.schemas, <String>{'dbo', 'sales'});
      expect(config.decimalMode, MssqlDecimalMode.text);
      expect(config.connection.decimalMode, MssqlDecimalMode.text);
      expect(config.output, endsWith('gen'));
    });

    test('written out rather than read from the environment, it warns', () {
      final config = parse("connection:\n  from: '$string'\n");
      expect(config.warnings, hasLength(1));
      expect(config.warnings.single, contains('env:NAME'));
    });

    test('an unset variable stops the run', () {
      expect(
        () => parse(
          'connection:\n  from: env:CS\n',
          environment: const <String, String>{},
        ),
        throwsA(isA<ConfigError>()),
      );
    });

    test('mixing it with the separate keys is refused', () {
      expect(
        () => parse(
          'connection:\n  from: env:CS\n  host: elsewhere\n',
          environment: const <String, String>{'CS': string},
        ),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('connection.host'), contains('Remove one')),
          ),
        ),
      );
    });

    test('a malformed string is refused where it is written', () {
      expect(
        () => parse(
          'connection:\n  from: env:CS\n',
          environment: const <String, String>{'CS': 'Database=Shop'},
        ),
        throwsArgumentError,
      );
    });

    test('keys this driver has no use for become a warning', () {
      final config = parse(
        'connection:\n  from: env:CS\n',
        environment: const <String, String>{
          'CS': '$string;Pooling=false;MultipleActiveResultSets=true',
        },
      );
      expect(
        config.warnings.any((w) => w.toLowerCase().contains('pooling')),
        isTrue,
        reason: config.warnings.toString(),
      );
    });
  });
}

void mainStrictConfig() {
  group('connection.encrypt', () {
    test('off by default, which is what it always silently was', () {
      expect(parse(_connection).connection.encryption, MssqlEncryption.off);
    });

    test('is actually applied', () {
      for (final entry in <String, MssqlEncryption>{
        'off': MssqlEncryption.off,
        'request': MssqlEncryption.request,
        'require': MssqlEncryption.require,
        'on': MssqlEncryption.require,
        'true': MssqlEncryption.require,
        'strict': MssqlEncryption.strict,
      }.entries) {
        final config = parse('''
connection:
  host: localhost
  database: Shop
  user: sa
  password: env:DB_PASSWORD
  encrypt: ${entry.key}
''');
        expect(config.connection.encryption, entry.value, reason: entry.key);
      }
    });

    test('reads the environment like every other connection key', () {
      final config = parse(
        '''
connection:
  host: localhost
  database: Shop
  user: sa
  password: env:DB_PASSWORD
  encrypt: env:DB_ENCRYPT
''',
        environment: const <String, String>{
          'DB_PASSWORD': 'secret',
          'DB_ENCRYPT': 'require',
        },
      );
      expect(config.connection.encryption, MssqlEncryption.require);
    });

    test('a value nobody defines is refused rather than downgraded', () {
      expect(
        () => parse('''
connection:
  host: localhost
  database: Shop
  user: sa
  password: env:DB_PASSWORD
  encrypt: sure
'''),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('off, request, require or strict'),
          ),
        ),
      );
    });
  });

  group('connection.trust_server_certificate', () {
    test('is refused, and says where trust is configured instead', () {
      expect(
        () => parse('''
connection:
  host: localhost
  database: Shop
  user: sa
  password: env:DB_PASSWORD
  trust_server_certificate: true
'''),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('MssqlRuntime.initialize'),
          ),
        ),
      );
    });
  });

  group('unknown keys', () {
    test('a misspelled root key is refused, with the spelling it meant', () {
      expect(
        () => parse('$_connection\nscafold: false\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"scafold"'), contains('did you mean "scaffold"')),
          ),
        ),
      );
    });

    test('a transposition is caught too', () {
      expect(
        () => parse('$_connection\noutupt: lib/db\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('did you mean "output"'),
          ),
        ),
      );
    });

    test('a key nothing resembles is still refused', () {
      expect(
        () => parse('$_connection\nwidgets: 3\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('"widgets"'),
          ),
        ),
      );
    });

    test('an unknown connection key is refused', () {
      expect(
        () => parse('''
connection:
  host: localhost
  database: Shop
  user: sa
  passwrod: env:DB_PASSWORD
'''),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('did you mean "password"'),
          ),
        ),
      );
    });

    test('the replaced decimal_as_double keeps its own message', () {
      expect(
        () => parse('$_connection\ndecimal_as_double: true\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('decimal_mode'),
          ),
        ),
      );
    });
  });

  group('booleans', () {
    test('a typo does not silently mean false', () {
      expect(
        () => parse('$_connection\nscaffold: ture\n'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(contains('scaffold'), contains('not true or false')),
          ),
        ),
      );
    });

    test('the spellings YAML 1.1 would have accepted still work', () {
      expect(parse('$_connection\nscaffold: "no"\n').scaffold, isFalse);
      expect(parse('$_connection\njson: "yes"\n').json, isTrue);
    });
  });

  group('requireSecrets: false', () {
    GeneratorConfig offline(String yaml) => GeneratorConfig.fromMap(
      loadYaml(yaml) as YamlMap,
      environment: const <String, String>{},
      requireSecrets: false,
    );

    test('falls back to offline when a secret is missing', () {
      expect(offline(_connection).connectionConfigured, isFalse);
    });

    test('does not swallow a mistake that has nothing to do with secrets', () {
      expect(
        () => offline('''
connection:
  host: localhost
  port: eighty
  database: Shop
  user: sa
  password: hunter2
'''),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('not a TCP port'),
          ),
        ),
      );
    });

    test('nor an unreadable encrypt', () {
      expect(
        () => offline('''
connection:
  host: localhost
  database: Shop
  user: sa
  password: hunter2
  encrypt: sure
'''),
        throwsA(isA<ConfigError>()),
      );
    });
  });
}

