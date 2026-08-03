import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/connection/notifier/connection_notifier.dart';
import 'package:marten/features/home/data/local_outbounds_provider.dart';
import 'package:marten/features/home/widget/subscription_panel.dart';
import 'package:marten/features/profile/model/profile_entity.dart';
import 'package:marten/features/profile/notifier/active_profile_notifier.dart';
import 'package:marten/features/profile/overview/profiles_notifier.dart';
import 'package:marten/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _selectedServerColor = Color(0xFF34323A);
late SharedPreferences sharedPreferences;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sharedPreferences = await SharedPreferences.getInstance();
  });

  final baseOutbounds = [
    const LocalOutbound(tag: 'Alpha', type: 'vless', server: 'alpha.example', serverPort: 443),
    const LocalOutbound(tag: 'Beta', type: 'hysteria2', server: 'beta.example', serverPort: 443),
    const LocalOutbound(tag: 'Gamma', type: 'wireguard', server: 'gamma.example', serverPort: 51820),
  ];

  final baseProfiles = [
    ProfileEntity.local(
      id: 'active-profile-id',
      active: true,
      name: 'Home Profile',
      lastUpdate: DateTime.utc(2026, 7, 31),
    ),
    ProfileEntity.local(
      id: 'backup-profile-id',
      active: false,
      name: 'Backup Profile',
      lastUpdate: DateTime.utc(2026, 7, 31),
    ),
    ProfileEntity.local(
      id: 'office-profile-id',
      active: false,
      name: 'Office Profile',
      lastUpdate: DateTime.utc(2026, 7, 31),
    ),
  ];

  testWidgets('disconnected panel раскрывает все server-строки и выделяет первую', (tester) async {
    final profileState = _ProfileSwitchHarness(baseProfiles);

    await _pumpPanel(
      tester,
      connectionStatus: const Disconnected(),
      outbounds: baseOutbounds,
      profileState: profileState,
    );

    for (final outbound in baseOutbounds) {
      expect(find.text(outbound.tag), findsOneWidget);
    }

    final firstY = tester.getTopLeft(find.text(baseOutbounds[0].tag)).dy;
    final secondY = tester.getTopLeft(find.text(baseOutbounds[1].tag)).dy;
    final thirdY = tester.getTopLeft(find.text(baseOutbounds[2].tag)).dy;
    expect(firstY < secondY, isTrue);
    expect(secondY < thirdY, isTrue);

    expect(_serverMaterial(tester, baseOutbounds[0].tag).color, _selectedServerColor);
    expect(_serverMaterial(tester, baseOutbounds[1].tag).color, Colors.transparent);
    expect(_serverMaterial(tester, baseOutbounds[2].tag).color, Colors.transparent);

    profileState.dispose();
  });

  testWidgets('disconnected переключает выбранный server и оставляет единственный активный', (tester) async {
    final profileState = _ProfileSwitchHarness(baseProfiles);

    await _pumpPanel(
      tester,
      connectionStatus: const Disconnected(),
      outbounds: baseOutbounds,
      profileState: profileState,
    );

    await tester.tap(_serverRow(tester, baseOutbounds[1].tag));
    await tester.pumpAndSettle();

    expect(_serverMaterial(tester, baseOutbounds[1].tag).color, _selectedServerColor);
    expect(_serverMaterial(tester, baseOutbounds[0].tag).color, Colors.transparent);
    expect(_serverMaterial(tester, baseOutbounds[2].tag).color, Colors.transparent);

    profileState.dispose();
  });

  testWidgets('connected показывает compact panel и игнорирует выбор неактивных', (tester) async {
    final profileState = _ProfileSwitchHarness(baseProfiles);

    await _pumpPanel(
      tester,
      connectionStatus: const Connected(),
      outbounds: baseOutbounds,
      profileState: profileState,
      allowProfileSwitch: false,
      proxiesOverview: _connectedOverview(baseOutbounds),
    );

    for (final outbound in baseOutbounds) {
      expect(find.text(outbound.tag), findsOneWidget);
    }

    await tester.tap(_serverRow(tester, baseOutbounds[1].tag));
    await tester.pumpAndSettle();

    expect(_serverMaterial(tester, baseOutbounds[0].tag).color, _selectedServerColor);
    expect(_serverMaterial(tester, baseOutbounds[1].tag).color, Colors.transparent);
    expect(_serverMaterial(tester, baseOutbounds[2].tag).color, Colors.transparent);

    profileState.dispose();
  });

  testWidgets('три профиля: expanded один сверху, collapsed-элементы ниже, клик по collapsed переключает active только при Disconnected', (
    tester,
  ) async {
    final profileState = _ProfileSwitchHarness(baseProfiles);

    await _pumpPanel(
      tester,
      connectionStatus: const Disconnected(),
      outbounds: baseOutbounds,
      profileState: profileState,
    );

    final active = profileState.activeProfile;
    final profileB = baseProfiles[1];
    final profileC = baseProfiles[2];

    final activeHeaderKey = ValueKey('subscription-profile-${active.id}-expanded');
    final activeBodyKey = ValueKey('subscription-profile-body-${active.id}');
    final collapsedHeaderKeyB = ValueKey('subscription-profile-${profileB.id}-collapsed');
    final collapsedHeaderKeyC = ValueKey('subscription-profile-${profileC.id}-collapsed');
    final expandedHeaderKeyB = ValueKey('subscription-profile-${profileB.id}-expanded');
    final expandedHeaderKeyC = ValueKey('subscription-profile-${profileC.id}-expanded');

    expect(find.byKey(activeHeaderKey), findsOneWidget);
    expect(find.byKey(activeBodyKey), findsOneWidget);
    expect(find.byKey(collapsedHeaderKeyB), findsOneWidget);
    expect(find.byKey(collapsedHeaderKeyC), findsOneWidget);
    expect(find.byKey(expandedHeaderKeyB), findsNothing);
    expect(find.byKey(expandedHeaderKeyC), findsNothing);

    final activeHeaderY = tester.getTopLeft(find.byKey(activeHeaderKey)).dy;
    expect(tester.getTopLeft(find.byKey(collapsedHeaderKeyB)).dy > activeHeaderY, isTrue);
    expect(tester.getTopLeft(find.byKey(collapsedHeaderKeyC)).dy > activeHeaderY, isTrue);

    await tester.tap(find.byKey(collapsedHeaderKeyB));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('subscription-profile-${profileB.id}-expanded')), findsOneWidget);
    expect(find.byKey(ValueKey('subscription-profile-${active.id}-expanded')), findsNothing);
    expect(find.byKey(ValueKey('subscription-profile-${active.id}-collapsed')), findsOneWidget);
    expect(find.byKey(ValueKey('subscription-profile-body-${profileB.id}')), findsOneWidget);

    profileState.dispose();
  });

  testWidgets('при Connected tap по collapsed профилю не меняет active profile', (tester) async {
    final profileState = _ProfileSwitchHarness(baseProfiles);

    await _pumpPanel(
      tester,
      connectionStatus: const Connected(),
      outbounds: baseOutbounds,
      profileState: profileState,
      allowProfileSwitch: false,
    );

    final active = profileState.activeProfile;
    final nextProfile = baseProfiles[1];

    await tester.tap(find.byKey(ValueKey('subscription-profile-${nextProfile.id}-collapsed')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('subscription-profile-${active.id}-expanded')), findsOneWidget);
    expect(find.byKey(ValueKey('subscription-profile-${nextProfile.id}-expanded')), findsNothing);

    profileState.dispose();
  });
}

OutboundGroup _connectedOverview(List<LocalOutbound> outbounds) {
  final items = outbounds
      .map(
        (outbound) => OutboundInfo(
          tag: outbound.tag,
          type: outbound.type,
          tagDisplay: outbound.tag,
          isSelected: outbound.tag == outbounds[0].tag,
        ),
      )
      .toList(growable: false);

  return OutboundGroup(
    tag: 'group-0',
    type: 'selector',
    selected: OutboundInfo(
      tag: outbounds[0].tag,
      type: outbounds[0].type,
      tagDisplay: outbounds[0].tag,
      isSelected: true,
    ),
    items: items,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required ConnectionStatus connectionStatus,
  required List<LocalOutbound> outbounds,
  required _ProfileSwitchHarness profileState,
  OutboundGroup? proxiesOverview,
  bool allowProfileSwitch = true,
}) async {
  profileState.allowSwitch = allowProfileSwitch;

  final overrides = <Override>[
    connectionNotifierProvider.overrideWith(() => _FixedConnectionNotifier(connectionStatus)),
    activeProfileProvider.overrideWith(() => _FixedActiveProfileNotifier(profileState)),
    profilesNotifierProvider.overrideWith(() => _FixedProfilesNotifier(profileState)),
    translationsProvider.overrideWith((_) => Translations()),
    selectedProxyByProfileProvider.overrideWith((_) => _FixedSelectedProxyByProfileNotifier(sharedPreferences)),
    localOutboundsProvider.overrideWith((_) => Future.value(outbounds)),
  ];

  if (proxiesOverview != null) {
    overrides.add(
      proxiesOverviewNotifierProvider.overrideWith(() => _FixedProxiesOverviewNotifier(proxiesOverview)),
    );
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: Scaffold(body: SubscriptionPanel())),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _serverRow(WidgetTester tester, String tag) {
  return find.ancestor(
    of: find.descendant(of: find.byType(ListView), matching: find.text(tag)),
    matching: find.byType(InkWell),
  );
}

Material _serverMaterial(WidgetTester tester, String tag) {
  final serverText = find.descendant(of: find.byType(ListView), matching: find.text(tag));
  final element = tester.element(serverText);
  final material = element.findAncestorWidgetOfExactType<Material>();
  if (material == null) {
    fail('Не найден Material-родитель для server [$tag]');
  }
  return material;
}

class _ProfileSwitchHarness {
  _ProfileSwitchHarness(List<ProfileEntity> initialProfiles) {
    _profiles = List<ProfileEntity>.from(initialProfiles);
    final active = initialProfiles.where((profile) => profile.active).firstOrNull;
    _activeProfile = active ?? initialProfiles.first;
    _normalizeActiveProfile();
    _emitCurrent();
  }

  late List<ProfileEntity> _profiles;
  late ProfileEntity _activeProfile;
  bool allowSwitch = true;

  final StreamController<List<ProfileEntity>> _profilesController = StreamController<List<ProfileEntity>>.broadcast();
  final StreamController<ProfileEntity?> _activeProfileController = StreamController<ProfileEntity?>.broadcast();

  List<ProfileEntity> get profiles => _profiles;
  ProfileEntity get activeProfile => _activeProfile;
  Stream<List<ProfileEntity>> get profilesStream => _profilesController.stream;
  Stream<ProfileEntity?> get activeProfileStream => _activeProfileController.stream;

  Future<void> select(String id) async {
    if (!allowSwitch) return;
    final nextIndex = _profiles.indexWhere((profile) => profile.id == id);
    if (nextIndex == -1) return;
    _activeProfile = _profiles[nextIndex];
    _normalizeActiveProfile();
    _emitCurrent();
  }

  void dispose() {
    _profilesController.close();
    _activeProfileController.close();
  }

  void _normalizeActiveProfile() {
    _profiles = _profiles.map((profile) {
      return profile.copyWith(active: profile.id == _activeProfile.id);
    }).toList(growable: false);
    final normalizedActive = _profiles.firstWhere((profile) => profile.id == _activeProfile.id, orElse: () => _activeProfile);
    _activeProfile = normalizedActive;
  }

  void _emitCurrent() {
    _profilesController.add(_profiles);
    _activeProfileController.add(_activeProfile);
  }
}

class _FixedConnectionNotifier extends ConnectionNotifier {
  _FixedConnectionNotifier(this.status);

  final ConnectionStatus status;

  @override
  Stream<ConnectionStatus> build() {
    state = AsyncData(status);
    return Stream.fromIterable([status]);
  }
}

class _FixedActiveProfileNotifier extends ActiveProfile {
  _FixedActiveProfileNotifier(this.profileState);

  final _ProfileSwitchHarness profileState;

  @override
  Stream<ProfileEntity?> build() {
    state = AsyncData(profileState.activeProfile);
    return profileState.activeProfileStream;
  }
}

class _FixedProfilesNotifier extends ProfilesNotifier {
  _FixedProfilesNotifier(this.profileState);

  final _ProfileSwitchHarness profileState;

  @override
  Stream<List<ProfileEntity>> build() {
    state = AsyncData(profileState.profiles);
    return profileState.profilesStream;
  }

  @override
  Future<Unit> selectActiveProfile(String id) async {
    await profileState.select(id);
    return unit;
  }
}

class _FixedProxiesOverviewNotifier extends ProxiesOverviewNotifier {
  _FixedProxiesOverviewNotifier(this.overview);

  final OutboundGroup overview;

  @override
  Stream<OutboundGroup?> build() {
    state = AsyncData(overview);
    return Stream.fromIterable([overview]);
  }
}

class _FixedSelectedProxyByProfileNotifier extends SelectedProxyByProfileNotifier {
  _FixedSelectedProxyByProfileNotifier(super.preferences);
}
