import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/profile/data/profile_auto_update_service.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/profile_notifier.dart';

void main() {
  group('shouldActivateImportedProfile', () {
    test('activates the first imported profile', () {
      expect(
        shouldActivateImportedProfile(
          activeProfile: null,
          connectionStatus: const Disconnected(),
          markNewProfileActive: false,
        ),
        isTrue,
      );
    });

    test('does not activate imports while a connection is active', () {
      expect(
        shouldActivateImportedProfile(
          activeProfile: _profile(),
          connectionStatus: const Connected(),
          markNewProfileActive: true,
        ),
        isFalse,
      );
    });

    test('respects the user preference while disconnected', () {
      expect(
        shouldActivateImportedProfile(
          activeProfile: _profile(),
          connectionStatus: const Disconnected(),
          markNewProfileActive: false,
        ),
        isFalse,
      );
      expect(
        shouldActivateImportedProfile(
          activeProfile: _profile(),
          connectionStatus: const Disconnected(),
          markNewProfileActive: true,
        ),
        isTrue,
      );
    });
  });

  group('ProfileAutoUpdateService.shouldUpdateProfile', () {
    test('updates remote profiles after the default one hour interval', () {
      final now = DateTime(2026, 5, 25, 12);
      expect(
        ProfileAutoUpdateService.shouldUpdateProfile(
          _remoteProfile(now.subtract(const Duration(minutes: 59))),
          now: now,
        ),
        isFalse,
      );
      expect(
        ProfileAutoUpdateService.shouldUpdateProfile(_remoteProfile(now.subtract(const Duration(hours: 1))), now: now),
        isTrue,
      );
    });

    test('respects custom intervals and disabled auto update', () {
      final now = DateTime(2026, 5, 25, 12);
      expect(
        ProfileAutoUpdateService.shouldUpdateProfile(
          _remoteProfile(now.subtract(const Duration(hours: 2)), interval: const Duration(hours: 3)),
          now: now,
        ),
        isFalse,
      );
      expect(
        ProfileAutoUpdateService.shouldUpdateProfile(
          _remoteProfile(now.subtract(const Duration(hours: 4)), interval: const Duration(hours: 3)),
          now: now,
        ),
        isTrue,
      );
      expect(
        ProfileAutoUpdateService.shouldUpdateProfile(
          _remoteProfile(now.subtract(const Duration(hours: 4)), disabled: true),
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('profile refresh request coalescing', () {
    test('an in-flight stronger request covers weaker duplicates', () {
      final now = DateTime.utc(2026, 7, 10);
      final running = (force: true, now: now, validate: true);

      expect(profileRefreshRequestCovers(running, (force: false, now: now, validate: false)), isTrue);
      expect(profileRefreshRequestCovers((force: false, now: now, validate: false), running), isFalse);
    });

    test('merges force and validation requirements for one follow-up', () {
      final firstTime = DateTime.utc(2026, 7, 10, 10);
      final latestTime = DateTime.utc(2026, 7, 10, 11);

      final merged = mergeProfileRefreshRequests(
        (force: true, now: firstTime, validate: false),
        (force: false, now: latestTime, validate: true),
      );

      expect(merged, (force: true, now: latestTime, validate: true));
    });
  });
}

ProfileEntity _profile() => ProfileEntity.local(id: 'active', active: true, name: 'Active', lastUpdate: DateTime(2026));

RemoteProfileEntity _remoteProfile(DateTime lastUpdate, {Duration? interval, bool disabled = false}) {
  return RemoteProfileEntity(
    id: 'remote',
    active: true,
    name: 'Remote',
    url: 'https://edge.example.com/sub/token',
    lastUpdate: lastUpdate,
    options: interval == null ? null : ProfileOptions(updateInterval: interval),
    userOverride: disabled ? const UserOverride(isAutoUpdateDisable: true) : null,
  );
}
