import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Started acknowledgement is bounded, immediate when healthy, and fails closed', () async {
    final source = await File('lib/martencore/core_interface/core_interface_mobile.dart').readAsString();
    final acknowledgement = functionBody(source, 'Future<bool> notifyBackgroundStarted() async');

    expect(source, contains('static const _platformStartedSyncTimeout = Duration(seconds: 115);'));
    expect(acknowledgement, contains('if (!Platform.isAndroid) return true;'));
    expect(
      acknowledgement,
      contains('invokeMethod<bool>("markStarted").timeout(_platformStartedSyncTimeout) ?? false'),
    );
    expect(acknowledgement, contains('platform started sync failed'));
    expect(acknowledgement, contains('return false;'));
    expect(acknowledgement, isNot(contains('while (')));
    expect(acknowledgement, isNot(contains('Future.delayed')));
    expect(acknowledgement, isNot(contains('Timer.periodic')));
  });

  test(
    'Dart Started acknowledgement stays attached for the bounded native TURNcoat retry and final in-flight proof',
    () async {
      final mobileInterface = await File('lib/martencore/core_interface/core_interface_mobile.dart').readAsString();
      final nativeProbe = await File(
        'android/app/src/main/kotlin/app/marten/client/bg/VpnDataPlaneProbe.kt',
      ).readAsString();
      final probePolicy = await File(
        'android/app/src/main/kotlin/app/marten/client/bg/VpnDataPlaneProbePolicy.kt',
      ).readAsString();
      final boxService = await File('android/app/src/main/kotlin/app/marten/client/bg/BoxService.kt').readAsString();
      final retry = functionBody(boxService, 'private suspend fun verifyNativeStartupRoute(');

      expect(nativeProbe, contains('private const val ACTIVE_VPN_WAIT_TIMEOUT_MS = 5_000L'));
      expect(nativeProbe, contains('verifyVpnDns('));
      expect(boxService, contains('private const val STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS = 75_000L'));
      expect(retry, contains('timeoutMs = if (usesTurncoat)'));
      expect(retry, contains('STARTUP_ROUTE_VERIFY_TURNCOAT_TIMEOUT_MS'));
      expect(retry, contains('requireVpnDataPlane = true'));
      expect(retry, contains('while (SystemClock.elapsedRealtime() < deadline)'));
      expect(probePolicy, contains('internal const val STANDARD_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS = 4_000L'));
      expect(probePolicy, contains('internal const val TURNCOAT_VPN_DATA_PLANE_ATTEMPT_TIMEOUT_MS = 30_000L'));
      expect(probePolicy, contains('minOf(preferred, remainingBudgetMs.coerceAtLeast(1L))'));
      expect(retry, contains('stopAndAlert(Alert.StartService'));
      expect(
        mobileInterface,
        contains('static const _platformStartedSyncTimeout = Duration(seconds: 115);'),
        reason:
            'Dart must cover the 75-second native retry window plus an already-started 30-second proof and 5-second VPN publication wait',
      );
    },
  );

  test('Android route verification delegates to native proof while non-Android retains its route probe', () async {
    final source = await File('lib/features/connection/data/connection_repository.dart').readAsString();
    final verification = functionBody(
      source,
      '@override\n  TaskEither<ConnectionFailure, Unit> verifyConnectedRoute({bool holdStartupRouteReady = false})',
    );
    final androidCondition = RegExp(r'if\s*\(\s*Platform\.isAndroid\s*\)').firstMatch(verification);

    expect(androidCondition, isNotNull);
    final androidBranch = blockAfter(verification, androidCondition!.start);
    final nonAndroidElse = RegExp(r'\}\s*else\s*\{').firstMatch(verification.substring(androidCondition.end));
    expect(nonAndroidElse, isNotNull);
    final nonAndroidBranch = blockAfter(verification, androidCondition.end + nonAndroidElse!.start);

    expect(androidBranch, contains('singbox.notifyBackgroundStarted()'));
    expect(androidBranch, contains('Android VPN data plane did not become ready'));
    expect(androidBranch, isNot(contains('_probeSelectedRouteHealth')));
    expect(androidBranch, isNot(contains('selectedUrlTestDelaySnapshot')));
    expect(nonAndroidBranch, contains('_probeSelectedRouteHealth()'));
    expect(
      verification.indexOf('verified = true;'),
      greaterThan(verification.indexOf('singbox.notifyBackgroundStarted()')),
    );
  });

  test('final startup acknowledgement is required before Android UI promotion', () async {
    final source = await File('lib/features/connection/data/connection_repository.dart').readAsString();
    final startup = functionBody(source, 'TaskEither<ConnectionFailure, Unit> _withPreparedConfig(');
    const acknowledgement = 'final platformAccepted = await singbox.notifyBackgroundStarted();';
    const reject = 'throw const ConnectionFailure.unexpected("Android VPN data plane did not become ready");';

    final acknowledgementOffset = startup.lastIndexOf(acknowledgement);
    final rejectOffset = startup.indexOf(reject, acknowledgementOffset);
    final promotionOffset = startup.indexOf('_setStartupRouteReady(true)', acknowledgementOffset);

    expect(acknowledgementOffset, greaterThanOrEqualTo(0));
    expect(rejectOffset, greaterThan(acknowledgementOffset));
    expect(promotionOffset, greaterThan(rejectOffset));
  });
}

String functionBody(String source, String declaration) {
  final declarationOffset = source.indexOf(declaration);
  if (declarationOffset < 0) throw StateError('function declaration not found: $declaration');
  final signatureStart = findCodeCharacter(source, declarationOffset, '(');
  if (signatureStart < 0) throw StateError('function parameter list not found: $declaration');
  final signatureEnd = matchingDelimiter(source, signatureStart, '(', ')');
  return blockAfter(source, signatureEnd + 1);
}

String blockAfter(String source, int start) {
  final bodyStart = findCodeCharacter(source, start, '{');
  if (bodyStart < 0) throw StateError('block start not found');
  var depth = 0;
  var index = bodyStart;
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      index = source.indexOf('\n', index + 2);
      if (index < 0) break;
      continue;
    }
    if (source.startsWith('/*', index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    final quote = source[index];
    if (quote == '"' || quote == "'") {
      index = skipQuotedLiteral(source, index, quote);
      continue;
    }
    if (quote == '{') depth++;
    if (quote == '}') {
      depth--;
      if (depth == 0) return source.substring(bodyStart, index + 1);
    }
    index++;
  }
  throw StateError('unterminated Dart block');
}

int findCodeCharacter(String source, int start, String target) {
  var index = start;
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      index = source.indexOf('\n', index + 2);
      if (index < 0) return -1;
      continue;
    }
    if (source.startsWith('/*', index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    final quote = source[index];
    if (quote == '"' || quote == "'") {
      index = skipQuotedLiteral(source, index, quote);
      continue;
    }
    if (quote == target) return index;
    index++;
  }
  return -1;
}

int skipQuotedLiteral(String source, int start, String quote) {
  final triple = '$quote$quote$quote';
  if (source.startsWith(triple, start)) {
    final end = source.indexOf(triple, start + 3);
    if (end < 0) throw StateError('unterminated Dart triple-quoted string');
    return end + 3;
  }
  var index = start + 1;
  while (index < source.length) {
    if (source[index] == r'\') {
      index += 2;
      continue;
    }
    if (source[index] == quote) return index + 1;
    index++;
  }
  throw StateError('unterminated Dart string');
}

int matchingDelimiter(String source, int start, String open, String close) {
  var depth = 0;
  var index = start;
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      index = source.indexOf('\n', index + 2);
      if (index < 0) break;
      continue;
    }
    if (source.startsWith('/*', index)) {
      index = skipBlockComment(source, index);
      continue;
    }
    final quote = source[index];
    if (quote == '"' || quote == "'") {
      index = skipQuotedLiteral(source, index, quote);
      continue;
    }
    if (quote == open) depth++;
    if (quote == close) {
      depth--;
      if (depth == 0) return index;
    }
    index++;
  }
  throw StateError('unterminated Dart delimiter');
}

int skipBlockComment(String source, int start) {
  var index = start + 2;
  while (index < source.length - 1) {
    if (source.startsWith('*/', index)) return index + 2;
    index++;
  }
  throw StateError('unterminated Dart block comment');
}
