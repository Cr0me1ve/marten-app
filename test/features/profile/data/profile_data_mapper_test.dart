import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/features/profile/data/profile_data_mapper.dart';
import 'package:marten/features/profile/model/profile_entity.dart';

void main() {
  test('stores subscription expiration without traffic metadata', () {
    final expiresAt = DateTime.utc(2026, 8, 14, 18, 45);
    final entry = ProfileEntity.remote(
      id: 'profile-1',
      active: true,
      name: 'Family VPN',
      url: 'https://edge.example.com/sub/token',
      lastUpdate: DateTime.utc(2026, 7, 14),
      expiresAt: expiresAt,
    ).toInsertEntry();

    expect(entry.expire.value, expiresAt);
    expect(entry.upload.value, isNull);
    expect(entry.download.value, isNull);
    expect(entry.total.value, isNull);
  });

  test('restores subscription expiration without creating fake traffic info', () {
    final expiresAt = DateTime.utc(2026, 8, 14, 18, 45);
    final profile =
        ProfileEntry(
              id: 'profile-1',
              type: ProfileType.remote,
              active: true,
              name: 'Family VPN',
              url: 'https://edge.example.com/sub/token',
              lastUpdate: DateTime.utc(2026, 7, 14),
              expire: expiresAt,
            ).toEntity()
            as RemoteProfileEntity;

    expect(profile.expiresAt, expiresAt);
    expect(profile.subInfo, isNull);
  });
}
