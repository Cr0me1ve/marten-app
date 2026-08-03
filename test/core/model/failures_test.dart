import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';

void main() {
  DioException httpError(int statusCode) {
    return DioException.badResponse(
      statusCode: statusCode,
      requestOptions: RequestOptions(path: 'https://example.test/sub'),
      response: Response<void>(
        requestOptions: RequestOptions(path: 'https://example.test/sub'),
        statusCode: statusCode,
      ),
    );
  }

  DioException connectionError() {
    return DioException.connectionError(
      requestOptions: RequestOptions(path: 'https://example.test/sub'),
      reason: 'Connection failed',
    );
  }

  test('presents common HTTP errors as short user-facing messages', () async {
    final t = await AppLocale.en.build();

    expect(httpError(404).present(t), (
      type: 'Subscription not found',
      message: 'The server could not find this subscription. Check the link or import a new one.',
    ));
    expect(httpError(429).present(t), (type: 'Error 429', message: 'Too many requests. Wait a bit and try again.'));
    expect(httpError(500).present(t), (type: 'Error 500', message: 'The server had an error. Try again later.'));
  });

  test('presents missing subscription distinctly for 404 responses', () async {
    final t = await AppLocale.ru.build();

    expect(httpError(404).present(t), (
      type: 'подписка не найдена',
      message: 'Сервер не нашёл эту подписку. Проверьте ссылку или импортируйте новую.',
    ));
  });

  test('presents unavailable server errors with the short Russian message', () async {
    final t = await AppLocale.ru.build();

    expect(connectionError().present(t), (type: 'сервер недоступен', message: null));
    expect(httpError(503).present(t), (type: 'сервер недоступен', message: null));
  });

  test('keeps subscription device mismatch message for 403 responses', () async {
    final t = await AppLocale.ru.build();

    expect(httpError(403).present(t), (
      type: 'Подписка привязана к другому устройству',
      message: 'Эта подписка привязана к другому устройству. Обратитесь к оператору для переноса.',
    ));
  });

  test('presents expired subscription distinctly for 410 responses', () async {
    final t = await AppLocale.ru.build();

    expect(httpError(410).present(t), (
      type: 'Подписка истекла',
      message: 'Эта подписка истекла. Обновите или импортируйте новую ссылку.',
    ));
  });

  test('presents unknown HTTP codes without leaking Dio details', () async {
    final t = await AppLocale.ru.build();

    expect(httpError(499).present(t), (
      type: 'Ошибка 499',
      message: 'Сервер отклонил запрос. Проверьте ссылку или доступ.',
    ));
    expect(httpError(599).present(t), (type: 'Ошибка 599', message: 'На сервере проблема. Попробуйте позже.'));
  });
}
