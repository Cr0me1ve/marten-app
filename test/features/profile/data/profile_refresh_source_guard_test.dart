import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String sourceFile(String path) => File(path).readAsStringSync();

  String classBody(String source, String className) {
    final classStart = source.indexOf('class $className');
    expect(classStart, isNonNegative, reason: 'could not find $className');
    final nextClass = source.indexOf('\n@riverpod', classStart + 1);
    expect(nextClass, isNonNegative, reason: 'could not find the end of $className');
    return source.substring(classStart, nextClass);
  }

  group('profile refresh source guards', () {
    test('manual refresh delegates to the coordinated auto-update service', () {
      final source = sourceFile('lib/features/profile/notifier/profile_notifier.dart');
      final updateNotifier = classBody(source, 'UpdateProfileNotifier');

      expect(
        updateNotifier,
        contains('ref.read(profileAutoUpdateServiceProvider).updateProfile(profile.id, force: true)'),
      );
      expect(updateNotifier, isNot(contains('upsertRemote(')));
      expect(updateNotifier, isNot(matches(RegExp(r'loggy\.warning\([\s\S]*?(?:err|error)'))));
      expect(updateNotifier, isNot(contains('connectionNotifierProvider')));
      expect(updateNotifier, isNot(contains('reconnect(active)')));
      expect(updateNotifier, isNot(contains('reconnect(profile)')));
      expect(updateNotifier, contains('subscription_refresh outcome=updated source=manual'));
    });

    test('subscription download markers keep endpoint and error details private', () {
      final source = sourceFile('lib/features/profile/data/profile_parser.dart');
      final downloadStart = source.indexOf('TaskEither<ProfileFailure, _ProfileDownloadResult> _downloadProfile(');
      final downloadEnd = source.indexOf('  @visibleForTesting\n  static Uri? refreshUrlFor', downloadStart);
      expect(downloadStart, isNonNegative, reason: 'could not find profile download flow');
      expect(downloadEnd, isNonNegative, reason: 'could not find end of profile download flow');
      final downloadFlow = source.substring(downloadStart, downloadEnd);

      expect(downloadFlow, contains('subscription_download phase=start'));
      expect(downloadFlow, contains("phase: 'attempt'"));
      expect(downloadFlow, contains("phase: 'failure'"));
      expect(downloadFlow, contains('phase=fallback'));
      expect(downloadFlow, contains('phase=rotate'));
      expect(downloadFlow, contains('phase=exhausted'));
      expect(downloadFlow, contains("'subscription_download phase=\$phase candidate_index=\$candidateIndex '"));

      expect(downloadFlow, contains(r'candidate_index=$candidateIndex'));
      expect(downloadFlow, contains(r'candidate_count=${candidates.length}'));
      expect(downloadFlow, contains(r'candidate_count=$candidateCount'));
      expect(downloadFlow, contains(r'method=$method'));
      expect(downloadFlow, contains(r'fallback=$fallback'));
      expect(downloadFlow, contains(r'category=${diagnostic.category}'));
      expect(downloadFlow, contains(r'error_type=${diagnostic.errorType}'));
      expect(downloadFlow, contains(r'http_status_class=${diagnostic.httpStatusClass}'));

      final downloadLogCalls = RegExp(
        r'loggy\.debug\(([\s\S]*?)\);',
      ).allMatches(downloadFlow).map((match) => match.group(1)!);
      for (final logCall in downloadLogCalls.where((call) => call.contains('subscription_download'))) {
        expect(
          logCall,
          isNot(
            matches(
              RegExp(
                r'\$(?:\{(?:candidate|err|error|lastError|targetUrl)\}|(?:candidate|err|error|lastError|targetUrl)(?![A-Za-z0-9_]))',
              ),
            ),
          ),
        );
        expect(logCall, isNot(contains('url=')));
        expect(logCall, isNot(contains('exception=')));
      }
      expect(downloadFlow, isNot(matches(RegExp(r'loggy\.(?:warning|error)\([\s\S]*?(?:err|error)'))));
    });
  });
}
