import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/features/profile/data/background_profile_refresh_scope.dart';

final class _TrackingDb extends Db {
  _TrackingDb() : super(NativeDatabase.memory());

  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    return super.close();
  }
}

void main() {
  test('closes its owned database exactly once, even when headless teardown repeats', () async {
    final database = _TrackingDb();
    final scope = BackgroundProfileRefreshScope(database: database);

    await scope.close();
    await scope.close();

    expect(database.closeCalls, 1);
  });
}
