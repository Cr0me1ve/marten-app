import 'dart:async';

import 'package:dio/dio.dart';

/// One deadline for endpoints, fallbacks, redirects and remote includes.
/// Wall time also accounts for a suspended iOS Runner when it resumes.
class SubscriptionDownloadBudget {
  SubscriptionDownloadBudget({required Duration timeout, CancelToken? parent})
    : _expiresAt = DateTime.now().add(timeout) {
    if (parent != null) {
      if (parent.isCancelled) {
        cancelToken.cancel(parent.cancelError);
      } else {
        unawaited(
          parent.whenCancel.then((error) {
            if (!_disposed) cancelToken.cancel(error);
          }),
        );
      }
    }
  }

  final DateTime _expiresAt;
  final CancelToken cancelToken = CancelToken();
  bool _expired = false;
  bool _disposed = false;

  DioException get _timeoutError =>
      DioException(requestOptions: RequestOptions(), type: DioExceptionType.receiveTimeout);

  void check() {
    if (_expired || !DateTime.now().isBefore(_expiresAt)) {
      _expired = true;
      cancelToken.cancel(_timeoutError);
      throw _timeoutError;
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
  }

  Future<T> run<T>(Future<T> Function() action) async {
    check();
    try {
      final result =
          await Future.any<T>([Future<T>.sync(action), cancelToken.whenCancel.then<T>((error) => throw error)]).timeout(
            _expiresAt.difference(DateTime.now()),
            onTimeout: () {
              _expired = true;
              cancelToken.cancel(_timeoutError);
              throw _timeoutError;
            },
          );
      check();
      return result;
    } catch (_) {
      check();
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    if (!cancelToken.isCancelled) cancelToken.cancel();
  }
}
