import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/profile/data/profile_parser.dart';
import 'package:marten/features/profile/model/profile_entity.dart';

ProfileEntity _profile({
  String id = 'profile-1',
  String name = 'Work',
  String? profileOverride = 'route: direct',
  UserOverride? userOverride,
  DateTime? lastUpdate,
  SubscriptionInfo? subInfo,
}) => ProfileEntity.remote(
  id: id,
  active: true,
  name: name,
  url: 'https://example.invalid/subscription',
  lastUpdate: lastUpdate ?? DateTime.utc(2025),
  profileOverride: profileOverride,
  userOverride: userOverride,
  subInfo: subInfo,
);

void main() {
  test('preserves connected session when refreshed metadata changes only', () {
    final previous = _profile(
      subInfo: SubscriptionInfo(upload: 10, download: 20, total: 100, expire: DateTime.utc(2025, 2)),
    );
    final next = _profile(
      lastUpdate: DateTime.utc(2025, 1, 2),
      subInfo: SubscriptionInfo(upload: 50, download: 60, total: 200, expire: DateTime.utc(2025, 3)),
    );

    expect(
      shouldPreserveConnectedSessionAfterProfileChange(
        previous: previous,
        next: next,
        activeRuntimeConfigMatches: true,
      ),
      isTrue,
    );
  });

  test('reconnects when active runtime configuration no longer matches', () {
    expect(
      shouldPreserveConnectedSessionAfterProfileChange(
        previous: _profile(),
        next: _profile(),
        activeRuntimeConfigMatches: false,
      ),
      isFalse,
    );
  });

  test('reconnects when profile identity, profile override, user override, or name changes', () {
    final original = _profile();

    for (final next in [
      _profile(id: 'profile-2'),
      _profile(profileOverride: 'route: proxy'),
      _profile(name: 'Personal'),
    ]) {
      expect(
        shouldPreserveConnectedSessionAfterProfileChange(
          previous: original,
          next: next,
          activeRuntimeConfigMatches: true,
        ),
        isFalse,
        reason: 'a changed identity or effective profile presentation/configuration requires reconnect',
      );
    }
  });

  test('preserves connected session when only user override refresh metadata changes', () {
    expect(
      shouldPreserveConnectedSessionAfterProfileChange(
        previous: _profile(userOverride: const UserOverride(updateInterval: 2)),
        next: _profile(userOverride: const UserOverride(isAutoUpdateDisable: true, updateInterval: 6)),
        activeRuntimeConfigMatches: true,
      ),
      isTrue,
    );
  });

  test('does not preserve session when either profile is absent', () {
    for (final pair in <(ProfileEntity?, ProfileEntity?)>[(null, _profile()), (_profile(), null), (null, null)]) {
      expect(
        shouldPreserveConnectedSessionAfterProfileChange(
          previous: pair.$1,
          next: pair.$2,
          activeRuntimeConfigMatches: true,
        ),
        isFalse,
      );
    }
  });

  test('subscription metadata is removed before outbound preparation, while endpoint changes remain', () {
    String prepare(String server, int upload) {
      final source = jsonEncode({
        'outbounds': [
          {'type': 'vless', 'tag': 'Chosen', 'server': server, 'server_port': 443, 'uuid': 'client-id'},
          {'type': 'direct', 'tag': 'direct'},
        ],
        'subscription': {'upload': upload, 'download': 20, 'total': 100, 'expires': '2025-02-01T00:00:00Z'},
      });
      final core = ProfileParser.stripMartenSubscriptionMetadata(source);
      return ProfileParser.stripMartenSubscriptionMetadata(prepareConfigForSelectedOutbound(core, 'Chosen'));
    }

    final original = prepare('edge.example.test', 10);
    final metadataRefreshed = prepare('edge.example.test', 900);
    final endpointChanged = prepare('new-edge.example.test', 10);

    expect(jsonDecode(metadataRefreshed), equals(jsonDecode(original)));
    expect(jsonDecode(endpointChanged), isNot(equals(jsonDecode(original))));
  });
}
