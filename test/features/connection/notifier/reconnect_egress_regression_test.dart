import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _functionBlock(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';

  var parenthesisDepth = 0;
  var open = -1;
  for (var index = start; index < source.length; index++) {
    switch (source[index]) {
      case '(':
        parenthesisDepth++;
      case ')':
        parenthesisDepth--;
      case '{' when parenthesisDepth == 0:
        open = index;
    }
    if (open >= 0) break;
  }
  if (open < 0) return '';

  var depth = 0;
  for (var index = open; index < source.length; index++) {
    switch (source[index]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return source.substring(open + 1, index);
    }
  }
  return '';
}

String _branchBlock(String source, String condition) {
  final start = source.indexOf(condition);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';

  var depth = 0;
  for (var index = open; index < source.length; index++) {
    switch (source[index]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return source.substring(open + 1, index);
    }
  }
  return '';
}

int _after(int index) => index < 0 ? 0 : index;

void main() {
  final source = File('lib/features/connection/notifier/connection_notifier.dart').readAsStringSync();

  test('profile reconnect transfers its exact sealed epoch to terminal native lifecycle ownership', () {
    final reconnect = _functionBlock(source, 'Future<void> reconnect(');
    final seal = reconnect.indexOf("final egressSeal = _sealAndroidOrdinaryNetworking('profile reconnect');");
    final ownership = reconnect.indexOf('_androidPlatformTransitionEgressEpoch = egressEpoch;', _after(seal));
    final sealAwait = reconnect.indexOf('await egressSeal;', _after(ownership));
    final restartLease = reconnect.indexOf(
      'final restartLease = await connectionRepo.tryBeginFlutterRestart();',
      _after(sealAwait),
    );
    final noLease = _branchBlock(reconnect, 'if (restartLease == null)');
    final invalidLease = _branchBlock(reconnect, 'if (!await connectionRepo.validateFlutterRestart(restartLease))');

    expect(reconnect, isNotEmpty);
    expect(seal, greaterThanOrEqualTo(0));
    expect(
      ownership,
      greaterThan(seal),
      reason: 'the profile-reconnect seal must retain its own epoch before native lifecycle work can terminally cancel',
    );
    expect(
      sealAwait,
      greaterThan(ownership),
      reason: 'ownership transfer must happen synchronously, before the seal itself can trigger a terminal status',
    );
    expect(restartLease, greaterThan(sealAwait));

    for (final terminalExit in [noLease, invalidLease]) {
      final exactImmediateRelease = terminalExit.indexOf(
        '_tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch)',
      );
      expect(terminalExit, isNotEmpty);
      if (exactImmediateRelease < 0) {
        expect(
          terminalExit,
          isNot(contains('_androidPlatformTransitionEgressEpoch = null;')),
          reason:
              'without an already-authoritative terminal release, native recovery must retain the exact epoch for Disconnected',
        );
      }
      expect(terminalExit, isNot(contains('_admitAndroidOrdinaryNetworking(egressEpoch)')));
    }
    expect(
      invalidLease,
      contains('_synchronizeAndroidTerminalUserIntent(repository: connectionRepo)'),
      reason: 'an invalid restart lease must reconcile the terminal native user intent without opening ordinary egress',
    );
  });

  test('authoritative Disconnected releases the transferred reconnect epoch exactly once', () {
    final build = _functionBlock(source, 'Stream<ConnectionStatus> build() async* {');
    final terminalStop = _branchBlock(build, 'if (nextStatus is Disconnected && previousStatus is! Disconnected)');
    final takeEpoch = terminalStop.indexOf('final platformEgressEpoch = _androidPlatformTransitionEgressEpoch;');
    final clearOwner = terminalStop.indexOf('_androidPlatformTransitionEgressEpoch = null;', _after(takeEpoch));
    final exactRelease = terminalStop.indexOf(
      '_releaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: platformEgressEpoch)',
      _after(clearOwner),
    );

    expect(build, isNotEmpty);
    expect(terminalStop, isNotEmpty);
    expect(takeEpoch, greaterThanOrEqualTo(0));
    expect(clearOwner, greaterThan(takeEpoch));
    expect(
      exactRelease,
      greaterThan(clearOwner),
      reason:
          'the authoritative terminal status must retire the captured profile-reconnect epoch, not a current implicit epoch',
    );
  });

  test('failed reconnect cleanup stays terminal while success forwards the same epoch to verified admission', () {
    final reconnect = _functionBlock(source, 'Future<void> reconnect(');
    final resultMatch = reconnect.indexOf('await result.match((err) async {');
    final cleanup = reconnect.indexOf('final cleanup = await connectionRepo.disconnect().run();', _after(resultMatch));
    final cleanupMatch = reconnect.indexOf('cleanup.match(', _after(cleanup));
    final cleanupFailure = reconnect.indexOf('(cleanupError)', _after(cleanupMatch));
    final cleanupSuccess = reconnect.indexOf('(_) {', _after(cleanupMatch));
    final releaseScheduled = reconnect.indexOf('releaseAfterRestartLease = true;', _after(cleanupSuccess));
    final admitted = reconnect.indexOf('(_) => _admitAndroidOrdinaryNetworking(egressEpoch)', _after(resultMatch));
    final releaseAfterLease = reconnect.indexOf(
      'if (releaseAfterRestartLease && Platform.isAndroid)',
      _after(admitted),
    );
    final exactRelease = reconnect.indexOf(
      '_tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect(expectedEpoch: egressEpoch)',
      _after(releaseAfterLease),
    );

    expect(reconnect, isNotEmpty);
    expect(resultMatch, greaterThanOrEqualTo(0));
    expect(cleanup, greaterThan(resultMatch));
    expect(cleanupMatch, greaterThan(cleanup));
    expect(
      cleanupFailure,
      greaterThan(cleanupMatch),
      reason: 'a failed native cleanup is reported and remains fail-closed; it cannot admit direct egress',
    );
    expect(cleanupSuccess, greaterThan(cleanupFailure));
    expect(
      releaseScheduled,
      greaterThan(cleanupSuccess),
      reason: 'only a successful cleanup can schedule terminal retirement of the reconnect epoch',
    );
    expect(
      admitted,
      greaterThan(cleanupMatch),
      reason: 'only the successful reconnect result may admit the original exact profile-reconnect epoch',
    );
    expect(releaseAfterLease, greaterThan(admitted));
    expect(
      exactRelease,
      greaterThan(releaseAfterLease),
      reason: 'post-lease terminal cleanup must release the exact captured profile-reconnect epoch',
    );
  });

  test('terminal release preserves native rejection and stale-epoch fail-closed guards', () {
    final release = _functionBlock(
      source,
      'Future<bool> _tryReleaseAndroidOrdinaryNetworkingAfterTerminalDisconnect({int? expectedEpoch}) async',
    );
    final staleEpoch = release.indexOf('if (expectedEpoch != null && expectedEpoch != _androidEgressEpoch)');
    final staleReturn = release.indexOf('return false;', _after(staleEpoch));
    final nativeRelease = release.indexOf(
      'await strictVpnEgressGate.releaseAfterTerminalDisconnect()',
      _after(staleReturn),
    );
    final nativeRejected = release.indexOf('if (!released) {', _after(nativeRelease));
    final nativeRejectedReturn = release.indexOf('return false;', _after(nativeRejected));
    final success = release.indexOf('return true;', _after(nativeRejectedReturn));

    expect(release, isNotEmpty);
    expect(staleEpoch, greaterThanOrEqualTo(0));
    expect(staleReturn, greaterThan(staleEpoch));
    expect(nativeRelease, greaterThan(staleReturn));
    expect(nativeRejected, greaterThan(nativeRelease));
    expect(
      nativeRejectedReturn,
      greaterThan(nativeRejected),
      reason: 'a native terminal predicate rejection must leave the strict egress gate closed',
    );
    expect(success, greaterThan(nativeRejectedReturn));
  });
}
