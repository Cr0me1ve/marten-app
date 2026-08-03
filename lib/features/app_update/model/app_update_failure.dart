import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';

part 'app_update_failure.freezed.dart';

@freezed
sealed class AppUpdateFailure with _$AppUpdateFailure, Failure {
  const AppUpdateFailure._();

  @With<UnexpectedFailure>()
  const factory AppUpdateFailure.unexpected([Object? error, StackTrace? stackTrace]) = AppUpdateUnexpectedFailure;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      AppUpdateUnexpectedFailure() => (type: t.errors.unexpected, message: null),
    };
  }
}
