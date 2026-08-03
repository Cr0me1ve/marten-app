import 'package:flutter_test/flutter_test.dart';
import 'package:marten/singbox/model/singbox_proxy_type.dart';

void main() {
  test('ICMP outbound is parsed as a selectable labeled proxy type', () {
    final type = ProxyType.fromJson('icmp');

    expect(type, ProxyType.icmp);
    expect(type.label, 'ICMP/WireGuard');
    expect(type.isGroup, isFalse);
  });
}
