import 'package:flutter_test/flutter_test.dart';
import 'package:marten/features/connection/model/connection_status.dart';
import 'package:marten/features/home/widget/connection_button.dart';

void main() {
  test('null status remains neutral while connection state is loading', () {
    expect(connectionButtonStatus(null), const Disconnected());
  });

  test('authoritative non-null connection states are preserved', () {
    for (final status in const <ConnectionStatus>[Connecting(), Connected(), Disconnecting(), Disconnected()]) {
      expect(connectionButtonStatus(status), status);
    }
  });

  test('connecting state with cold-attach verification flag stays non-switching for button policy', () {
    const status = Connecting(existingSessionVerification: true);

    expect(connectionButtonStatus(status), status);
    expect(status.isSwitching, isFalse);
  });

  test('normal connecting remains switching while cold-attach verification is absent', () {
    expect(const Connecting().isSwitching, isTrue);
  });
}
