import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marten/core/db/db.dart';
import 'package:marten/features/profile/data/profile_data_source.dart';
import 'package:marten/features/profile/model/profile_entity.dart';

void main() {
  late Db db;
  late ProfileDao dao;

  setUp(() {
    db = Db(NativeDatabase.memory());
    dao = ProfileDao(db);
  });

  tearDown(() => db.close());

  test('getByUrl uses exact subscription identity instead of SQL substring matching', () async {
    await dao.insert(
      ProfileEntriesCompanion.insert(
        id: 'profile-long-token',
        type: ProfileType.remote,
        active: true,
        name: 'Remote',
        url: const Value('https://edge.example/sub/token-extra'),
        lastUpdate: DateTime.utc(2026, 7, 10),
      ),
    );

    expect(await dao.getByUrl('https://edge.example/sub/token'), isNull);
    expect((await dao.getByUrl('https://edge.example/sub/token-extra'))?.id, 'profile-long-token');
  });
}
