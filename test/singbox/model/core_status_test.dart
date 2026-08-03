import 'package:flutter_test/flutter_test.dart';
import 'package:marten/martencore/generated/v2/hcore/hcore.pb.dart';
import 'package:marten/singbox/model/core_status.dart';

void main() {
  test('already stopped core info is not surfaced as a connection failure', () {
    final status = CoreStatus.fromCoreInfo(
      CoreInfoResponse(coreState: CoreStates.STOPPED, messageType: MessageType.ALREADY_STOPPED),
    );

    expect(status, isA<CoreStopped>().having((status) => status.alert, 'alert', isNull));
    expect(status.getCoreAlert(), isNull);
  });
}
