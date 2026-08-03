import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/core/model/failures.dart';
import 'package:marten/features/settings/model/config_option_failure.dart';

part 'connection_failure.freezed.dart';

const missingProfileConfigFailureMessage = 'marten:profile-config-file-missing';

@freezed
sealed class ConnectionFailure with _$ConnectionFailure, Failure {
  const ConnectionFailure._();

  @With<UnexpectedFailure>()
  const factory ConnectionFailure.unexpected([Object? error, StackTrace? stackTrace]) = UnexpectedConnectionFailure;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.missingVpnPermission([String? message]) = MissingVpnPermission;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.missingNotificationPermission([String? message]) = MissingNotificationPermission;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.missingPrivilege() = MissingPrivilege;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.invalidConfigOption([String? message, ConfigOptionFailure? configOptionFailure]) =
      InvalidConfigOption;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.invalidConfig([String? message]) = InvalidConfig;

  @With<ExpectedMeasuredFailure>()
  const factory ConnectionFailure.backgroundCoreNotAvailable([String? message]) = BackgroundCoreNotAvailable;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      UnexpectedConnectionFailure(:final error) when looksLikeSelectedRouteConnectivityError(error) =>
        presentServerUnavailableError(t, message: t.errors.connection.selectedRouteFailedMsg),
      InvalidConfig(:final message) when message == missingProfileConfigFailureMessage => (
        type: t.errors.profiles.notFound,
        message: null,
      ),
      UnexpectedConnectionFailure(:final error) when looksLikeCoreStartConnectivityError(error) => (
        type: t.errors.connection.connectionError,
        message: t.errors.connection.startFailedMsg,
      ),
      UnexpectedConnectionFailure(:final error) when error != null => (
        type: t.errors.connectivity.unexpected,
        message: "$error",
      ),
      UnexpectedConnectionFailure() => (type: t.errors.connectivity.unexpected, message: null),
      MissingVpnPermission(:final message) => (type: t.errors.connectivity.missingVpnPermission, message: message),
      MissingNotificationPermission(:final message) => (
        type: t.errors.connectivity.missingNotificationPermission,
        message: message,
      ),
      MissingPrivilege() => (type: t.errors.singbox.missingPrivilege, message: t.errors.singbox.missingPrivilegeMsg),
      InvalidConfigOption(:final message, :final configOptionFailure) =>
        configOptionFailure?.present(t) ?? (type: t.errors.singbox.invalidConfigOptions, message: message),
      InvalidConfig(:final message) => (type: t.errors.singbox.invalidConfig, message: message),
      BackgroundCoreNotAvailable(:final message) => (type: t.errors.connectivity.core, message: message),
    };
  }
}

bool looksLikeCoreStartConnectivityError(Object? error) {
  if (error == null) return false;
  final message = error.toString().trim().toLowerCase();
  if (message == 'failed to start background core') return true;
  if (message.contains('createservice')) return true;
  if (message.contains('create service')) return true;
  if (message.contains('startservice')) return true;
  if (message.contains('foreground core setup timed out')) return true;
  if (message.contains('foreground core did not answer')) return true;
  if (message.contains('no available foreground core grpc port')) return true;
  if (message.contains('no available background core grpc port')) return true;
  if (message.contains('starting background core')) return true;
  if (message.contains('background core is not started yet')) return true;
  if (message.contains('selected route failed startup connectivity check')) return true;
  if (message.contains('startup route test timed out')) return true;
  if (message.contains('connection timed out while waiting for turncoat route')) return true;
  if (message.contains('connection timed out while starting core')) return true;
  if (message.contains('missing default interface')) return true;
  if (message.contains('missing default network')) return true;
  if (message.contains('network is unreachable')) return true;
  if (message.contains('no route to host')) return true;
  if (message.contains('no such host')) return true;
  if (message.contains('failed to resolve')) return true;
  if (message.contains('temporary failure in name resolution')) return true;
  return message.contains('i/o timeout') || message.contains('connection timed out');
}

bool looksLikeSelectedRouteConnectivityError(Object? error) {
  if (error == null) return false;
  final message = error.toString().trim().toLowerCase();
  return message.contains('selected route failed startup connectivity check') ||
      message.contains('startup route test timed out') ||
      message.contains('connection timed out while waiting for turncoat route');
}
