import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourcePath = 'lib/features/app/widget/app.dart';

  test('Quick Settings inactive lifecycle state never pauses the foreground core', () {
    final source = File(sourcePath).readAsStringSync();
    final lifecycleListener = _functionBlock(source, 'void setupStateListener(WidgetRef ref)');
    final onPause = _functionBlock(source, 'void onPause(WidgetRef ref)');

    final pausedState = lifecycleListener.indexOf('AppLifecycleState.paused');
    final pauseCall = lifecycleListener.indexOf('onPause(ref);', pausedState);
    final resumedState = lifecycleListener.indexOf('AppLifecycleState.resumed');
    final resumeCall = lifecycleListener.indexOf('onResume(ref);', resumedState);

    expect(
      pausedState,
      greaterThanOrEqualTo(0),
      reason: 'a genuine background pause must retain foreground-core shutdown',
    );
    expect(
      pauseCall,
      greaterThan(pausedState),
      reason: 'only AppLifecycleState.paused may mark the app paused and close the foreground core',
    );
    expect(
      lifecycleListener,
      isNot(contains('AppLifecycleState.inactive')),
      reason: 'notification shade and Quick Settings inactive transitions must not invoke lifecycle pause work',
    );
    expect(
      resumedState,
      greaterThanOrEqualTo(0),
      reason: 'the foreground resume lifecycle path must remain installed',
    );
    expect(
      resumeCall,
      greaterThan(resumedState),
      reason: 'AppLifecycleState.resumed must still restore the foreground path',
    );
    expect(onPause, contains('isOnPauseCalled = true;'));
    expect(onPause, contains('martenCoreServiceProvider).closeFront();'));
  });
}

String _functionBlock(String source, String signature) {
  final declaration = source.indexOf(signature);
  expect(declaration, greaterThanOrEqualTo(0), reason: 'missing $signature');
  final openingBrace = source.indexOf('{', declaration);
  expect(openingBrace, greaterThanOrEqualTo(0), reason: '$signature has no body');

  var depth = 0;
  for (var index = openingBrace; index < source.length; index++) {
    switch (source[index]) {
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return source.substring(openingBrace, index + 1);
    }
  }
  fail('$signature body does not close');
}
