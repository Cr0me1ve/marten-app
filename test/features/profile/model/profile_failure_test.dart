import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/profile/model/profile_failure.dart';

void main() {
  test('presentProfileUpdateError uses deviceLimit message without action prefix in ru/en', () async {
    final tEn = await AppLocale.en.build();
    final tRu = await AppLocale.ru.build();

    final enResult = presentProfileUpdateError(tEn, const ProfileFailure.deviceLimit(), action: 'Update profile');
    final ruResult = presentProfileUpdateError(tRu, const ProfileFailure.deviceLimit(), action: 'Обновить подписку');

    expect(enResult, 'The device limit for this subscription has been reached');
    expect(ruResult, 'Достигнут лимит устройств для этой подписки');
  });

  test('presentProfileUpdateError keeps action prefix for non-deviceLimit profile failures', () async {
    final tEn = await AppLocale.en.build();
    final tRu = await AppLocale.ru.build();

    final enResult = presentProfileUpdateError(tEn, const ProfileFailure.notFound(), action: 'Retry');
    final ruResult = presentProfileUpdateError(tRu, const ProfileFailure.notFound(), action: 'Повторить');

    expect(enResult, 'Retry: Profile not found');
    expect(ruResult, 'Повторить: Профиль не найден');
  });

  test('deviceLimit translation exists and is not missing fallback for all locales', () async {
    final projectRoot = Directory.current.path;
    final enFile = File('$projectRoot/assets/translations/en.i18n.json');
    final enContent = jsonDecode(await enFile.readAsString()) as Map<String, dynamic>;
    final enType = (enContent['errors'] as Map<String, dynamic>)['profiles'] as Map<String, dynamic>;
    final enDeviceLimit = enType['deviceLimit'] as String?;
    expect(enDeviceLimit, isNotEmpty);

    final translationsDir = Directory('$projectRoot/assets/translations');
    final files = translationsDir
        .listSync()
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.i18n.json') &&
              file.uri.pathSegments.isNotEmpty &&
              file.uri.pathSegments.last != 'en.i18n.json',
        )
        .toList();

    for (final file in files) {
      final content = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final type = ((content['errors'] as Map<String, dynamic>)['profiles'] as Map<String, dynamic>)['deviceLimit'];
      expect(type, isA<String>(), reason: file.path);
      expect(type, isNotEmpty, reason: file.path);
      expect(type, isNot(equals(enDeviceLimit)), reason: file.path);
    }
  });
}
