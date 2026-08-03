import 'package:dio/dio.dart';
import 'package:grpc/grpc.dart';
import 'package:marten/core/localization/translations.dart';

typedef PresentableError = ({String type, String? message});

PresentableError presentServerUnavailableError(TranslationsEn t, {String? message}) {
  if (_isRuLocale(t)) return (type: 'сервер недоступен', message: null);
  return (type: t.errors.connection.connectionError, message: message);
}

bool _isRuLocale(TranslationsEn t) => t.$meta.locale.languageCode == 'ru';

mixin Failure {
  ({String type, String? message}) present(TranslationsEn t);
}

/// failures that are not expected to happen but depending on [error] type might not be relevant (eg network errors)
mixin UnexpectedFailure {
  Object? get error;
  StackTrace? get stackTrace;
}

/// failures that are expected to happen and should be handled by the app
/// and should be logged, eg missing permissions
mixin ExpectedMeasuredFailure {}

/// failures ignored by analytics service etc.
mixin ExpectedFailure {}

extension ErrorPresenter on TranslationsEn {
  PresentableError errorToPair(Object error) => switch (error) {
    GrpcError(message: final nestedErr?) => errorToPair(nestedErr),
    UnexpectedFailure(error: final nestedErr?) => errorToPair(nestedErr),
    Failure() => error.present(this),
    DioException() => error.present(this),
    _ => (type: errors.unexpected, message: error.toString()),
  };

  PresentableError presentError(Object error, {String? action}) {
    final pair = errorToPair(error);
    if (action == null) return pair;
    return (type: action, message: pair.type + (pair.message == null ? "" : "\n${pair.message!}"));
  }

  String presentShortError(Object error, {String? action}) {
    final pair = errorToPair(error);
    if (action == null) return pair.type;
    return "$action: ${pair.type}";
  }
}

extension DioExceptionPresenter on DioException {
  bool get isDeviceMismatch => type == DioExceptionType.badResponse && response?.statusCode == 403;

  PresentableError present(TranslationsEn t) => switch (type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => (type: t.errors.connection.timeout, message: null),
    DioExceptionType.badCertificate => (type: t.errors.connection.badCertificate, message: _badCertificateMessage(t)),
    DioExceptionType.badResponse when response?.statusCode == 410 => (
      type: _subscriptionExpiredTitle(t),
      message: _subscriptionExpiredMessage(t),
    ),
    DioExceptionType.badResponse when response?.statusCode == 404 => (
      type: _subscriptionNotFoundTitle(t),
      message: _subscriptionNotFoundMessage(t),
    ),
    DioExceptionType.badResponse when response?.statusCode == 403 => (
      type: t.errors.profiles.deviceMismatch,
      message: t.errors.profiles.deviceMismatchMsg,
    ),
    DioExceptionType.badResponse => _presentHttpStatus(t, response?.statusCode),
    DioExceptionType.connectionError => presentServerUnavailableError(t, message: _connectionErrorMessage(t)),
    _ => (type: t.errors.connection.unexpected, message: _unexpectedConnectionMessage(t)),
  };

  PresentableError _presentHttpStatus(TranslationsEn t, int? statusCode) {
    if (statusCode == null) {
      return (type: t.errors.connection.badResponse, message: _badResponseMessage(t));
    }
    if (statusCode == 503 && _isRu(t)) return presentServerUnavailableError(t);
    return (type: _httpStatusTitle(t, statusCode), message: _httpStatusMessage(t, statusCode));
  }

  String _httpStatusTitle(TranslationsEn t, int statusCode) {
    if (_isRu(t)) return 'Ошибка $statusCode';
    return 'Error $statusCode';
  }

  String _httpStatusMessage(TranslationsEn t, int statusCode) {
    if (_isRu(t)) return _ruHttpStatusMessage(statusCode);
    return _enHttpStatusMessage(statusCode);
  }

  bool _isRu(TranslationsEn t) => _isRuLocale(t);

  String _subscriptionExpiredTitle(TranslationsEn t) => _isRu(t) ? 'Подписка истекла' : 'Subscription expired';

  String _subscriptionExpiredMessage(TranslationsEn t) => _isRu(t)
      ? 'Эта подписка истекла. Обновите или импортируйте новую ссылку.'
      : 'This subscription has expired. Renew it or import a new link.';

  String _subscriptionNotFoundTitle(TranslationsEn t) => _isRu(t) ? 'подписка не найдена' : 'Subscription not found';

  String _subscriptionNotFoundMessage(TranslationsEn t) => _isRu(t)
      ? 'Сервер не нашёл эту подписку. Проверьте ссылку или импортируйте новую.'
      : 'The server could not find this subscription. Check the link or import a new one.';

  String _ruHttpStatusMessage(int statusCode) => switch (statusCode) {
    100 => 'Сервер принял начало запроса. Попробуйте ещё раз.',
    101 => 'Сервер меняет протокол соединения. Попробуйте ещё раз.',
    102 => 'Сервер всё ещё обрабатывает запрос. Подождите немного.',
    103 => 'Сервер прислал промежуточный ответ. Попробуйте ещё раз.',
    200 => 'Запрос выполнен успешно.',
    201 => 'Данные успешно созданы.',
    202 => 'Запрос принят, но ещё не обработан.',
    203 => 'Сервер вернул изменённый ответ.',
    204 => 'Сервер ответил без данных.',
    205 => 'Сервер просит повторить ввод данных.',
    206 => 'Сервер вернул только часть данных.',
    207 => 'Сервер вернул смешанный результат.',
    208 => 'Эти данные уже были обработаны.',
    226 => 'Сервер вернул результат с изменениями.',
    300 => 'Сервер предлагает несколько вариантов ответа.',
    301 => 'Адрес подписки изменился навсегда.',
    302 => 'Адрес подписки временно изменился.',
    303 => 'Для этого запроса нужен другой адрес.',
    304 => 'Данные не изменились.',
    305 => 'Для запроса нужен прокси.',
    307 => 'Адрес временно изменился. Попробуйте позже.',
    308 => 'Адрес подписки изменился навсегда.',
    400 => 'Сервер не понял запрос. Проверьте ссылку подписки.',
    401 => 'Нужна авторизация. Проверьте ссылку или доступ к подписке.',
    402 => 'Доступ к подписке недоступен или отключён.',
    403 => 'Нет доступа. Проверьте, что подписка открыта для этого устройства.',
    404 => 'Сервер не нашёл подписку. Проверьте ссылку.',
    405 => 'Сервер не поддерживает этот способ запроса.',
    406 => 'Сервер не может отдать данные в нужном формате.',
    407 => 'Прокси требует авторизацию.',
    408 => 'Сервер слишком долго ждал запрос. Попробуйте ещё раз.',
    409 => 'На сервере конфликт данных. Попробуйте обновить позже.',
    410 => 'Подписка истекла. Обновите или импортируйте новую ссылку.',
    411 => 'Серверу не хватает данных о размере запроса.',
    412 => 'Условия запроса не выполнены.',
    413 => 'Запрос слишком большой для сервера.',
    414 => 'Ссылка слишком длинная для сервера.',
    415 => 'Сервер не поддерживает формат данных.',
    416 => 'Сервер не может отдать запрошенную часть данных.',
    417 => 'Сервер не смог выполнить ожидаемое условие запроса.',
    418 => 'Сервер вернул необычный ответ. Попробуйте ещё раз.',
    421 => 'Запрос попал не на тот сервер.',
    422 => 'Сервер понял запрос, но не смог обработать данные.',
    423 => 'Данные временно заблокированы на сервере.',
    424 => 'Запрос не выполнен из-за другой ошибки на сервере.',
    425 => 'Сервер просит повторить запрос позже.',
    426 => 'Сервер требует обновить протокол соединения.',
    428 => 'Для запроса нужны дополнительные условия.',
    429 => 'Слишком много запросов. Подождите немного и попробуйте снова.',
    431 => 'Слишком большие заголовки запроса.',
    451 => 'Доступ ограничен по юридическим причинам.',
    500 => 'На сервере произошла ошибка. Попробуйте позже.',
    501 => 'Сервер не поддерживает этот запрос.',
    502 => 'Сервер получил неверный ответ от другого сервера.',
    503 => 'Сервер временно недоступен. Попробуйте позже.',
    504 => 'Сервер слишком долго ждал ответ. Попробуйте позже.',
    505 => 'Сервер не поддерживает версию HTTP.',
    506 => 'На сервере ошибка настройки.',
    507 => 'На сервере не хватает места для обработки запроса.',
    508 => 'Сервер обнаружил цикл при обработке запроса.',
    510 => 'Серверу нужны дополнительные возможности для запроса.',
    511 => 'Сначала нужно пройти авторизацию в сети.',
    >= 100 && < 200 => 'Сервер обрабатывает запрос. Попробуйте ещё раз.',
    >= 200 && < 300 => 'Сервер ответил успешно, но без ожидаемых данных.',
    >= 300 && < 400 => 'Сервер перенаправил запрос. Проверьте ссылку подписки.',
    >= 400 && < 500 => 'Сервер отклонил запрос. Проверьте ссылку или доступ.',
    >= 500 && < 600 => 'На сервере проблема. Попробуйте позже.',
    _ => 'Сервер вернул неизвестный HTTP-код $statusCode.',
  };

  String _enHttpStatusMessage(int statusCode) => switch (statusCode) {
    100 => 'The server accepted the start of the request. Try again.',
    101 => 'The server is switching the connection protocol. Try again.',
    102 => 'The server is still processing the request. Wait a moment.',
    103 => 'The server sent an early response. Try again.',
    200 => 'The request completed successfully.',
    201 => 'The data was created successfully.',
    202 => 'The request was accepted but has not finished yet.',
    203 => 'The server returned a modified response.',
    204 => 'The server responded without data.',
    205 => 'The server asks to reset the entered data.',
    206 => 'The server returned only part of the data.',
    207 => 'The server returned a mixed result.',
    208 => 'This data was already processed.',
    226 => 'The server returned the result with changes applied.',
    300 => 'The server offers several response options.',
    301 => 'The subscription address has permanently changed.',
    302 => 'The subscription address has temporarily changed.',
    303 => 'This request needs a different address.',
    304 => 'The data has not changed.',
    305 => 'This request requires a proxy.',
    307 => 'The address changed temporarily. Try again later.',
    308 => 'The subscription address has permanently changed.',
    400 => 'The server could not understand the request. Check the subscription link.',
    401 => 'Authorization is required. Check the link or subscription access.',
    402 => 'Subscription access is unavailable or disabled.',
    403 => 'Access is denied. Check that the subscription is available for this device.',
    404 => 'The server could not find the subscription. Check the link.',
    405 => 'The server does not support this request method.',
    406 => 'The server cannot return data in the required format.',
    407 => 'The proxy requires authorization.',
    408 => 'The server waited too long for the request. Try again.',
    409 => 'The server has a data conflict. Try updating later.',
    410 => 'The subscription has expired. Renew it or import a new link.',
    411 => 'The server needs the request size.',
    412 => 'The request conditions were not met.',
    413 => 'The request is too large for the server.',
    414 => 'The link is too long for the server.',
    415 => 'The server does not support this data format.',
    416 => 'The server cannot return the requested part of the data.',
    417 => 'The server could not meet the expected request condition.',
    418 => 'The server returned an unusual response. Try again.',
    421 => 'The request reached the wrong server.',
    422 => 'The server understood the request but could not process the data.',
    423 => 'The data is temporarily locked on the server.',
    424 => 'The request failed because of another server error.',
    425 => 'The server asks to retry the request later.',
    426 => 'The server requires a protocol upgrade.',
    428 => 'The request needs additional conditions.',
    429 => 'Too many requests. Wait a bit and try again.',
    431 => 'The request headers are too large.',
    451 => 'Access is restricted for legal reasons.',
    500 => 'The server had an error. Try again later.',
    501 => 'The server does not support this request.',
    502 => 'The server received an invalid response from another server.',
    503 => 'The server is temporarily unavailable. Try again later.',
    504 => 'The server waited too long for a response. Try again later.',
    505 => 'The server does not support this HTTP version.',
    506 => 'The server has a configuration error.',
    507 => 'The server does not have enough storage to process the request.',
    508 => 'The server detected a loop while processing the request.',
    510 => 'The server needs additional features for this request.',
    511 => 'Network authorization is required first.',
    >= 100 && < 200 => 'The server is processing the request. Try again.',
    >= 200 && < 300 => 'The server responded successfully, but without the expected data.',
    >= 300 && < 400 => 'The server redirected the request. Check the subscription link.',
    >= 400 && < 500 => 'The server rejected the request. Check the link or access.',
    >= 500 && < 600 => 'The server has a problem. Try again later.',
    _ => 'The server returned unknown HTTP status $statusCode.',
  };

  String _badCertificateMessage(TranslationsEn t) {
    if (_isRu(t)) return 'Не удалось проверить безопасность соединения. Проверьте дату на устройстве или ссылку.';
    return 'The connection could not be verified. Check the device date or the link.';
  }

  String _badResponseMessage(TranslationsEn t) {
    if (_isRu(t)) return 'Сервер ответил неожиданно. Попробуйте ещё раз позже.';
    return 'The server responded unexpectedly. Try again later.';
  }

  String _connectionErrorMessage(TranslationsEn t) {
    if (_isRu(t)) return 'Не удалось подключиться. Проверьте интернет и попробуйте снова.';
    return 'Could not connect. Check your internet connection and try again.';
  }

  String _unexpectedConnectionMessage(TranslationsEn t) {
    if (_isRu(t)) return 'Что-то пошло не так при подключении. Попробуйте ещё раз.';
    return 'Something went wrong while connecting. Try again.';
  }
}
