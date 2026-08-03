import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/profile/details/profile_details_notifier.dart';

void main() {
  group('profileContentForSave', () {
    const raw = '{"dns":{"servers":[{"tag":"secure"}]},"route":{"rules":[{"action":"route"}]},"outbounds":[]}';
    const displayed = '{"outbounds":[]}';

    test('preserves the complete raw profile for metadata-only edits', () {
      expect(
        profileContentForSave(rawConfigContent: raw, displayedConfigContent: displayed, contentChanged: false),
        raw,
      );
    });

    test('uses edited content only after an explicit content edit', () {
      expect(
        profileContentForSave(rawConfigContent: raw, displayedConfigContent: displayed, contentChanged: true),
        displayed,
      );
    });
  });
}
