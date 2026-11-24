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

/// Имитация облака с почтовыми аккаунтами.
class _AccountCloud {
  final accounts = <String, ({String uid, String password})>{};
  final documents = <String, Map<String, dynamic>>{};
  var anon = 0;
  var refreshBody = '';
  final requests = <String>[];

  http.Response ok(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  http.Response fail(String message) => http.Response(
    jsonEncode({
      'error': {'message': message},
    }),
    400,
  );

  Future<http.Response> handle(http.Request request) async {
    try {
      return await _handle(request);
    } catch (error) {
      // ignore: avoid_print
      print('FAKE ERROR ${request.url.path}: $error');
      rethrow;
    }
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    requests.add(path.split('/').last);
    final body = request.headers['content-type']?.contains('json') == true
        ? jsonDecode(request.body)
        : {};
    if (path.endsWith('accounts:signUp')) {
      final token = body['idToken'] as String?;
      if (token != null) {
        final email = body['email'] as String;
        if (accounts.containsKey(email)) return fail('EMAIL_EXISTS');
        final uid = token.substring(3);
        accounts[email] = (uid: uid, password: body['password'] as String);
        return ok({
          'idToken': 'id-$uid',
          'refreshToken': 'r-$uid',
          'localId': uid,
        });
      }
      anon++;
      return ok({
        'idToken': 'id-anon$anon',
        'refreshToken': 'r-anon$anon',
        'localId': 'anon$anon',
      });
    }
    if (path.endsWith('accounts:signInWithPassword')) {
      final account = accounts[body['email']];
      if (account == null || account.password != body['password']) {
        return fail('INVALID_LOGIN_CREDENTIALS');
      }
      final uid = account.uid;
      return ok({
        'idToken': 'id-$uid',
        'refreshToken': 'r-$uid',
        'localId': uid,
      });
    }
    if (path.endsWith('accounts:lookup')) {
      return ok({
        'users': [
          {'emailVerified': false},
        ],
      });
    }
    if (path.endsWith('accounts:sendOobCode') ||
        path.endsWith('accounts:delete')) {
      return ok({});
    }
    if (path.endsWith('/v1/token')) {
      if (refreshBody.isNotEmpty) return fail(refreshBody);
      final uid = request.bodyFields['refresh_token']!.substring(2);
      return ok({
        'id_token': 'id-$uid',
        'refresh_token': 'r-$uid',
        'user_id': uid,
      });
    }
    if (path.endsWith(':commit')) {
      for (final write in body['writes'] as List) {
        final update = write['update'];
        if (update != null) {
          documents[update['name'] as String] = Map<String, dynamic>.from(
            update['fields'] as Map,
          );
        } else {
          documents.remove(write['delete']);
        }
      }
      return ok({});
    }
    if (request.method == 'GET') {
      final name = path.substring('/v1/'.length);
      if (name.endsWith('/entries')) {
        return ok({
          'documents': [
            for (final item in documents.entries)
              if (item.key.startsWith('$name/'))
                {'name': item.key, 'fields': item.value},
          ],
        });
      }
      final document = documents[name];
      return document == null
          ? http.Response('{}', 404)
          : ok({'name': name, 'fields': document});
    }
    return http.Response('unexpected', 500);
  }
}

NialCloudEntry _entry(String id, String text) => NialCloudEntry(
  id: id,
  title: 'Запись $id',
  text: text,
  date: DateTime.utc(2026, 11, 25),
  favorite: false,
);

void main() {
  late _AccountCloud cloud;
  NialCloudSync create(_MemoryStore store) => NialCloudSync(
    client: MockClient(cloud.handle),
    store: store,
    apiKey: 'key',
    projectId: 'demo',
    keyPrefix: 'nial_public_',
    profileSnapshot: () async => (name: 'Никита', about: 'пишу'),
    debounce: Duration.zero,
  );

  setUp(() => cloud = _AccountCloud());

  test('регистрация привязывает почту к той же облачной копии', () async {
    final store = _MemoryStore();
    final sync = create(store);
    await sync.load();
    await sync.setEnabled(true);
    await sync.sync([_entry('a', 'текст')]);
    final uid = store.values['nial_public_cloud_uid_v1'];
    await sync.register('me@example.com', 'secret1');
    expect(store.values['nial_public_cloud_uid_v1'], uid);
    expect(sync.status.value.email, 'me@example.com');
    expect(sync.status.value.enabled, isTrue);
    expect(cloud.requests, contains('accounts:sendOobCode'));
    expect(
      cloud
          .documents['projects/demo/databases/(default)/documents/users/$uid']!['name'],
      {'stringValue': 'Никита'},
    );
  });

  test(
    'вход на новом телефоне возвращает записи и профиль без удаления',
    () async {
      final first = create(_MemoryStore());
      await first.load();
      await first.register('me@example.com', 'secret1');
      await first.sync([_entry('a', 'один'), _entry('b', 'два')]);

      final store = _MemoryStore();
      final second = create(store);
      await second.load();
      final restore = await second.signIn('me@example.com', 'secret1');
      expect(restore.entries.map((e) => e.id).toSet(), {'a', 'b'});
      expect(restore.name, 'Никита');
      final report = await second.sync([
        ...restore.entries,
        _entry('c', 'три'),
      ]);
      expect(report.removed, 0);
      expect(
        cloud.documents.keys.where((k) => k.contains('/entries/')).length,
        3,
      );
    },
  );

  test(
    'при входе анонимная копия этого телефона удаляется из облака',
    () async {
      final owner = create(_MemoryStore());
      await owner.load();
      await owner.register('me@example.com', 'secret1');

      final store = _MemoryStore();
      final phone = create(store);
      await phone.load();
      await phone.setEnabled(true);
      await phone.sync([_entry('x', 'аноним')]);
      final anonUid = store.values['nial_public_cloud_uid_v1']!;
      await phone.signIn('me@example.com', 'secret1');
      expect(cloud.documents.keys.where((k) => k.contains(anonUid)), isEmpty);
    },
  );

  test('неверный пароль и занятая почта дают понятные ошибки', () async {
    final owner = create(_MemoryStore());
    await owner.load();
    await owner.register('me@example.com', 'secret1');
    final other = create(_MemoryStore());
    await other.load();
    await expectLater(
      other.signIn('me@example.com', 'wrong12'),
      throwsA(predicate((e) => '$e' == 'Неверная почта или пароль.')),
    );
    await expectLater(
      other.register('me@example.com', 'secret1'),
      throwsA(predicate((e) => '$e'.contains('уже зарегистрирована'))),
    );
  });

  test('выход очищает сессию, но не трогает облако', () async {
    final store = _MemoryStore();
    final sync = create(store);
    await sync.load();
    await sync.register('me@example.com', 'secret1');
    await sync.sync([_entry('a', 'один')]);
    final docs = cloud.documents.length;
    await sync.signOut();
    expect(store.values, isEmpty);
    expect(sync.status.value.email, isNull);
    expect(sync.status.value.enabled, isFalse);
    expect(cloud.documents.length, docs);
  });

  test('устаревший вход в аккаунт не подменяется анонимным', () async {
    final store = _MemoryStore();
    final sync = create(store);
    await sync.load();
    await sync.register('me@example.com', 'secret1');
    final restarted = create(store);
    await restarted.load();
    cloud.refreshBody = 'TOKEN_EXPIRED';
    final anonBefore = cloud.anon;
    await expectLater(
      restarted.sync([_entry('a', 'один')]),
      throwsA(predicate((e) => '$e'.contains('Войди по почте снова'))),
    );
    expect(cloud.anon, anonBefore);
    expect(restarted.status.value.email, isNull);
    expect(restarted.status.value.enabled, isFalse);
  });
}
