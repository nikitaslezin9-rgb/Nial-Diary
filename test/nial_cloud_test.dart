import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nial_diary/services/nial_cloud.dart';

class _MemoryStore implements NialCloudStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// Имитация облака: анонимный вход, обновление токена и хранение документов.
class _FakeCloud {
  final documents = <String, Map<String, dynamic>>{};
  final commits = <List<dynamic>>[];
  var signUps = 0;
  var refreshes = 0;
  var accountsDeleted = 0;
  var failCommits = false;
  var refreshError = '';

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('accounts:signUp')) {
      signUps++;
      return http.Response(
        jsonEncode({
          'idToken': 'id-$signUps',
          'refreshToken': 'refresh-$signUps',
          'localId': 'uid$signUps',
          'expiresIn': '3600',
        }),
        200,
      );
    }
    if (request.url.host == 'securetoken.googleapis.com') {
      refreshes++;
      if (refreshError.isNotEmpty) {
        return http.Response(
          jsonEncode({
            'error': {'message': refreshError},
          }),
          400,
        );
      }
      expect(request.bodyFields['grant_type'], 'refresh_token');
      return http.Response(
        jsonEncode({
          'id_token': 'id-r$refreshes',
          'refresh_token': request.bodyFields['refresh_token'],
          'user_id': 'uid$signUps',
          'expires_in': '3600',
        }),
        200,
      );
    }
    if (path.endsWith('accounts:delete')) {
      accountsDeleted++;
      return http.Response('{}', 200);
    }
    if (path.endsWith(':commit')) {
      if (failCommits) return http.Response('{"error":{}}', 503);
      expect(request.headers['Authorization'], startsWith('Bearer id-'));
      final writes = (jsonDecode(request.body) as Map)['writes'] as List;
      commits.add(writes);
      for (final write in writes) {
        if (write['delete'] != null) {
          documents.remove(write['delete']);
        } else {
          documents[write['update']['name'] as String] =
              Map<String, dynamic>.from(write['update']['fields'] as Map);
        }
      }
      return http.Response('{}', 200);
    }
    if (request.method == 'GET' && path.endsWith('/entries')) {
      return http.Response(
        jsonEncode({
          'documents': [
            for (final name in documents.keys)
              if (name.contains('/entries/')) {'name': name},
          ],
        }),
        200,
      );
    }
    return http.Response('unexpected ${request.url}', 404);
  }
}

NialCloudEntry _entry(String id, String text, {bool favorite = false}) =>
    NialCloudEntry(
      id: id,
      title: 'Заголовок $id',
      text: text,
      date: DateTime.utc(2026, 11, 24, 10),
      favorite: favorite,
    );

void main() {
  late _FakeCloud cloud;
  late _MemoryStore store;
  late NialCloudSync sync;

  NialCloudSync create() => NialCloudSync(
    client: MockClient(cloud.handle),
    store: store,
    apiKey: 'key',
    projectId: 'demo',
    debounce: Duration.zero,
  );

  setUp(() {
    cloud = _FakeCloud();
    store = _MemoryStore();
    sync = create();
  });

  Iterable<String> entryDocs() =>
      cloud.documents.keys.where((name) => name.contains('/entries/'));

  test('выключенная копия ничего не отправляет', () async {
    await sync.load();
    final report = await sync.sync([_entry('a', 'текст')]);
    expect(report.uploaded, 0);
    expect(cloud.signUps, 0);
    expect(cloud.commits, isEmpty);
  });

  test('первая отправка создаёт документы и сведения о копии', () async {
    await sync.setEnabled(true);
    final report = await sync.sync([
      _entry('a', 'первая'),
      _entry('b', 'вторая', favorite: true),
    ]);
    expect(report.uploaded, 2);
    expect(report.removed, 0);
    expect(cloud.signUps, 1);
    const base = 'projects/demo/databases/(default)/documents/users/uid1';
    expect(entryDocs(), {'$base/entries/a', '$base/entries/b'});
    expect(cloud.documents['$base/entries/b']!['favorite'], {
      'booleanValue': true,
    });
    expect(cloud.documents['$base/entries/a']!['text'], {
      'stringValue': 'первая',
    });
    expect(cloud.documents[base]!['entryCount'], {'integerValue': '2'});
    expect(sync.status.value.lastSyncAt, isNotNull);
    expect(sync.status.value.error, isNull);
  });

  test('повторная отправка без изменений не делает запросов', () async {
    await sync.setEnabled(true);
    final entries = [_entry('a', 'первая')];
    await sync.sync(entries);
    final before = cloud.commits.length;
    final report = await sync.sync(entries);
    expect(report.uploaded, 0);
    expect(cloud.commits.length, before);
  });

  test('изменённая запись обновляется, удалённая удаляется', () async {
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'первая'), _entry('b', 'вторая')]);
    final report = await sync.sync([_entry('a', 'первая, исправлено')]);
    expect(report.uploaded, 1);
    expect(report.removed, 1);
    expect(entryDocs().length, 1);
    expect(
      cloud.documents.values.any(
        (fields) => fields['text']?['stringValue'] == 'первая, исправлено',
      ),
      isTrue,
    );
  });

  test('после перезапуска используется прежний облачный профиль', () async {
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'первая')]);
    final restarted = create();
    await restarted.load();
    expect(restarted.status.value.enabled, isTrue);
    await restarted.sync([_entry('a', 'первая'), _entry('b', 'вторая')]);
    expect(cloud.signUps, 1);
    expect(cloud.refreshes, 1);
    expect(entryDocs().length, 2);
    expect(entryDocs().every((name) => name.contains('/users/uid1/')), isTrue);
  });

  test('если облачный профиль пропал, копия создаётся заново', () async {
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'первая')]);
    final restarted = create();
    await restarted.load();
    cloud.refreshError = 'USER_NOT_FOUND';
    await restarted.sync([_entry('a', 'первая')]);
    expect(cloud.signUps, 2);
    expect(
      cloud.documents.keys,
      contains(
        'projects/demo/databases/(default)/documents/users/uid2/entries/a',
      ),
    );
  });

  test('ошибка облака не теряет изменения и видна в статусе', () async {
    await sync.setEnabled(true);
    cloud.failCommits = true;
    await expectLater(
      sync.sync([_entry('a', 'первая')]),
      throwsA(isA<NialCloudException>()),
    );
    expect(sync.status.value.error, isNotNull);
    expect(sync.status.value.busy, isFalse);
    cloud.failCommits = false;
    final report = await sync.sync([_entry('a', 'первая')]);
    expect(report.uploaded, 1);
    expect(sync.status.value.error, isNull);
  });

  test('большой дневник отправляется несколькими пакетами', () async {
    await sync.setEnabled(true);
    final report = await sync.sync([
      for (var i = 0; i < 450; i++) _entry('id$i', 'запись $i'),
    ]);
    expect(report.uploaded, 450);
    expect(cloud.commits.length, 3);
    expect(entryDocs().length, 450);
  });

  test('слишком длинный текст обрезается и помечается', () async {
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'я' * 200001)]);
    final fields = cloud.documents.values.firstWhere(
      (item) => item.containsKey('text'),
    );
    expect((fields['text']['stringValue'] as String).length, 200000);
    expect(fields['truncated'], {'booleanValue': true});
  });

  test('повреждённые идентификаторы не отправляются', () async {
    await sync.setEnabled(true);
    for (final entries in [
      [_entry('a/b', 'x')],
      [_entry('a', 'x'), _entry('a', 'y')],
    ]) {
      await expectLater(
        sync.sync(entries),
        throwsA(isA<NialCloudException>()),
      );
    }
    expect(cloud.commits, isEmpty);
  });

  test('удаление копии очищает облако и выключает отправку', () async {
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'первая'), _entry('b', 'вторая')]);
    await sync.deleteCloudCopy();
    expect(cloud.documents, isEmpty);
    expect(cloud.accountsDeleted, 1);
    expect(sync.status.value.enabled, isFalse);
    expect(store.values, isEmpty);
  });

  test('отложенная отправка срабатывает сама', () async {
    await sync.setEnabled(true);
    sync.schedule(() => [_entry('a', 'первая')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(entryDocs().length, 1);
  });

  test('отпечаток меняется вместе с содержимым', () {
    expect(_entry('a', 'x').fingerprint, _entry('a', 'x').fingerprint);
    expect(
      _entry('a', 'x').fingerprint,
      isNot(_entry('a', 'y').fingerprint),
    );
    expect(
      _entry('a', 'x').fingerprint,
      isNot(_entry('a', 'x', favorite: true).fingerprint),
    );
  });
}
