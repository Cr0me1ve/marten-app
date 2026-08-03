import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/localization/translations.dart';
import 'package:marten/features/profile/model/profile_sort_enum.dart';

void main() {
  test('presents profile sort labels for the matching sort key', () async {
    final t = await AppLocale.en.build();

    expect(ProfilesSort.lastUpdate.present(t), t.dialogs.sortProfiles.sort.lastUpdate);
    expect(ProfilesSort.name.present(t), t.dialogs.sortProfiles.sort.name);
  });
}
