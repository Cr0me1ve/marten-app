import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/features/profile/model/profile_entity.dart';

extension ProfileEntityMapper on ProfileEntity {
  ProfileEntriesCompanion toInsertEntry() => map(
    remote: (rp) => ProfileEntriesCompanion.insert(
      id: rp.id,
      type: ProfileType.remote,
      active: rp.active,
      name: rp.name,
      url: Value(rp.url),
      lastUpdate: rp.lastUpdate,
      updateInterval: Value(rp.options?.updateInterval),
      populatedHeaders: Value(jsonEncode(rp.populatedHeaders)),
      profileOverride: Value(rp.profileOverride),
      userOverride: Value(rp.userOverride?.toStr()),
      upload: Value(rp.subInfo?.upload),
      download: Value(rp.subInfo?.download),
      total: Value(rp.subInfo?.total),
      expire: Value(rp.expiresAt ?? rp.subInfo?.expire),
      webPageUrl: Value(rp.subInfo?.webPageUrl),
      supportUrl: Value(rp.subInfo?.supportUrl),
      subscriptionEndpoints: Value(jsonEncode(rp.subscriptionEndpoints)),
      currentSubscriptionEndpoint: Value(rp.currentSubscriptionEndpoint),
      unavailableSubscriptionEndpoints: Value(jsonEncode(rp.unavailableSubscriptionEndpoints)),
    ),
    local: (lp) => ProfileEntriesCompanion.insert(
      id: lp.id,
      type: ProfileType.local,
      active: lp.active,
      name: lp.name,
      lastUpdate: lp.lastUpdate,
      populatedHeaders: Value(jsonEncode(lp.populatedHeaders)),
      profileOverride: Value(lp.profileOverride),
      userOverride: Value(lp.userOverride?.toStr()),
    ),
  );

  ProfileEntriesCompanion toUpdateEntry() => map(
    remote: (rp) => ProfileEntriesCompanion(
      name: Value(rp.name),
      lastUpdate: Value(rp.lastUpdate),
      updateInterval: Value(rp.options?.updateInterval),
      populatedHeaders: Value(jsonEncode(rp.populatedHeaders)),
      profileOverride: Value(rp.profileOverride),
      userOverride: Value(rp.userOverride?.toStr()),
      upload: Value(rp.subInfo?.upload),
      download: Value(rp.subInfo?.download),
      total: Value(rp.subInfo?.total),
      expire: Value(rp.expiresAt ?? rp.subInfo?.expire),
      webPageUrl: Value(rp.subInfo?.webPageUrl),
      supportUrl: Value(rp.subInfo?.supportUrl),
      subscriptionEndpoints: Value(jsonEncode(rp.subscriptionEndpoints)),
      currentSubscriptionEndpoint: Value(rp.currentSubscriptionEndpoint),
      unavailableSubscriptionEndpoints: Value(jsonEncode(rp.unavailableSubscriptionEndpoints)),
    ),
    local: (lp) => ProfileEntriesCompanion(
      name: Value(lp.name),
      lastUpdate: Value(lp.lastUpdate),
      populatedHeaders: Value(jsonEncode(lp.populatedHeaders)),
      profileOverride: Value(lp.profileOverride),
      userOverride: Value(lp.userOverride?.toStr()),
    ),
  );
}

extension ProfileEntryMapper on ProfileEntry {
  ProfileEntity toEntity() {
    ProfileOptions? options;
    if (updateInterval != null) {
      options = ProfileOptions(updateInterval: updateInterval!);
    }

    SubscriptionInfo? subInfo;
    if (upload != null && download != null && total != null && expire != null) {
      subInfo = SubscriptionInfo(
        upload: upload!,
        download: download!,
        total: total!,
        expire: expire!,
        webPageUrl: webPageUrl,
        supportUrl: supportUrl,
      );
    }
    Map<String, dynamic>? mPopulatedHeaders;

    if (populatedHeaders != null) {
      final m = jsonDecode(populatedHeaders!) as Map;
      mPopulatedHeaders = m.cast<String, dynamic>();
    }

    return switch (type) {
      ProfileType.remote => RemoteProfileEntity(
        id: id,
        active: active,
        name: name,
        url: url!,
        lastUpdate: lastUpdate,
        options: options,
        subInfo: subInfo,
        expiresAt: expire,
        subscriptionEndpoints: _decodeStringList(subscriptionEndpoints),
        currentSubscriptionEndpoint: currentSubscriptionEndpoint,
        unavailableSubscriptionEndpoints: _decodeStringList(unavailableSubscriptionEndpoints),
        populatedHeaders: mPopulatedHeaders,
        profileOverride: profileOverride,
        userOverride: UserOverride.fromStr(userOverride),
      ),
      ProfileType.local => LocalProfileEntity(
        id: id,
        active: active,
        name: name,
        lastUpdate: lastUpdate,
        populatedHeaders: mPopulatedHeaders,
        profileOverride: profileOverride,
        userOverride: UserOverride.fromStr(userOverride),
      ),
    };
  }
}

List<String> _decodeStringList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.map((item) => item.toString().trim()).where((item) => item.isNotEmpty).toList(growable: false);
  } catch (_) {
    return const [];
  }
}
