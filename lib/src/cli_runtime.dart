import 'dart:io';

import 'package:mssql_native/mssql_native.dart';

/// Process-wide TLS for generator CLIs.
Future<void> initializeCliRuntime() {
  final insecure = _flag('MSSQL_TLS_INSECURE');
  final system = _flag('MSSQL_TLS_SYSTEM');
  final ca = Platform.environment['MSSQL_TLS_CA'];
  final MssqlTlsTrust? tls;
  if (insecure) {
    tls = const MssqlTlsTrust.insecureNoVerification();
  } else if (ca != null && ca.isNotEmpty) {
    tls = MssqlTlsTrust(certificateAuthorityFile: ca);
  } else if (system) {
    tls = const MssqlTlsTrust.system();
  } else {
    tls = null;
  }
  return MssqlRuntime.instance.initialize(tls: tls);
}

bool _flag(String name) {
  final raw = Platform.environment[name];
  if (raw == null || raw.isEmpty) return false;
  final folded = raw.toLowerCase();
  return folded == '1' || folded == 'true' || folded == 'yes';
}

/// One-line TLS advice for doctor and connection failures.
String cliTlsHint() =>
    'Encrypted connections need process-wide trust: set MSSQL_TLS_CA to a '
    'PEM bundle, MSSQL_TLS_SYSTEM=1 for OpenSSL default paths, or '
    'MSSQL_TLS_INSECURE=1 to encrypt without verifying. Plaintext is the '
    'default (connection.encryption: off).';
