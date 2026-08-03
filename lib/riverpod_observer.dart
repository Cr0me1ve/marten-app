import 'dart:developer';

import 'package:hooks_riverpod/hooks_riverpod.dart';

class RiverpodObserver extends ProviderObserver {
  String _describe(Object? value) {
    if (value == null) return 'null';
    return value.runtimeType.toString();
  }

  @override
  void didAddProvider(ProviderBase<Object?> provider, Object? value, ProviderContainer container) {
    log('didAddProvider : ${provider.name ?? provider.runtimeType} : ${_describe(value)}');
  }

  @override
  void didDisposeProvider(ProviderBase<Object?> provider, ProviderContainer container) {
    log('didDisposeProvider : ${provider.name ?? provider.runtimeType}');
  }

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    log(
      'didUpdateProvider : ${provider.name ?? provider.runtimeType} : ${_describe(previousValue)} -> ${_describe(newValue)}',
    );
  }
}
