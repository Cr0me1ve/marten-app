import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/connection/model/connection_failure.dart';

void main() {
  test('presents background core start failure as a readable connection error', () async {
    final t = await AppLocale.ru.build();
    final error = const ConnectionFailure.unexpected('failed to start background core').present(t);

    expect(error.type, 'Ошибка подключения');
    expect(error.message, contains('Проверьте интернет'));
  });

  test('recognizes transient core startup failures for readable errors', () {
    const failures = [
      'createService - null',
      'foreground core setup timed out on 127.0.0.1:17078',
      'foreground core did not answer on 127.0.0.1:17078',
      'no available foreground core gRPC port in 17078-17120',
      'no available background core gRPC port in 17078-17120',
      'starting background core timed out',
      'background core is not started yet!',
      'selected route failed startup connectivity check',
      'startup route test timed out',
      'connection timed out while waiting for TURNcoat route',
      'missing default interface',
      'network is unreachable',
    ];

    for (final failure in failures) {
      expect(looksLikeCoreStartConnectivityError(failure), isTrue, reason: failure);
    }
  });

  test('presents selected route startup failure as node-specific user error', () async {
    final t = await AppLocale.ru.build();
    final error = const ConnectionFailure.unexpected('selected route failed startup connectivity check').present(t);

    expect(error.type, 'сервер недоступен');
    expect(error.message, isNull);
  });

  test('presents missing profile config file as profile not found', () async {
    final t = await AppLocale.ru.build();
    final error = const ConnectionFailure.invalidConfig(missingProfileConfigFailureMessage).present(t);

    expect(error.type, 'Профиль не найден');
    expect(error.message, isNull);
  });

  test('does not classify user-action or config failures as startup connectivity errors', () {
    const failures = ['bad json', 'bad option', 'missing vpn permission', 'missing notification permission'];

    for (final failure in failures) {
      expect(looksLikeCoreStartConnectivityError(failure), isFalse, reason: failure);
    }
  });
}
