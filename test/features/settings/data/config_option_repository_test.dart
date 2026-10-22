import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:marten/core/preferences/preferences_provider.dart';
import 'package:marten/features/settings/data/config_option_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late SharedPreferences preferences;
  late ConfigOptionRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWith((_) => Future.value(preferences))],
    );
    await container.read(sharedPreferencesProvider.future);
    repository = ConfigOptionRepository(
      preferences: preferences,
      getConfigOptions: () => container.read(ConfigOptions.singboxConfigOptions),
    );
  });

  tearDown(() => container.dispose());

  test('tolerates malformed and unknown overrides while retaining valid sibling fields', () {
    final base = repository.fullOptions().getOrElse((failure) => fail('base options failed: $failure'));

    final malformed = repository
        .fullOptionsOverrided('{not-json')
        .getOrElse((failure) => fail('malformed override must be ignored: $failure'));
    expect(malformed, base);

    final unknownTopLevel = repository
        .fullOptionsOverrided('{"future-option":true,"block-ads":true}')
        .getOrElse((failure) => fail('unknown top-level field must not reject valid sibling: $failure'));
    expect(unknownTopLevel.blockAds, isTrue);
    expect(unknownTopLevel.mtu, base.mtu);

    final invalidTopLevel = repository
        .fullOptionsOverrided('{"mtu":"not-a-number","block-ads":true}')
        .getOrElse((failure) => fail('invalid top-level field must not reject valid sibling: $failure'));
    expect(invalidTopLevel.blockAds, isTrue);
    expect(invalidTopLevel.mtu, base.mtu);

    final invalidNestedLeaf = repository
        .fullOptionsOverrided(
          '{"tls-tricks":{"future-leaf":true,"fragment-size":"not-a-range","enable-fragment":true}}',
        )
        .getOrElse((failure) => fail('invalid nested leaf must not reject valid sibling: $failure'));
    expect(invalidNestedLeaf.tlsTricks.enableFragment, isTrue);
    expect(invalidNestedLeaf.tlsTricks.fragmentSize.format(), base.tlsTricks.fragmentSize.format());
  });
}
