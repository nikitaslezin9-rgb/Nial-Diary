import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'nial_cloud_config.dart';

/// Текстовая часть записи, которая уходит в облачную копию.
/// Фото, голосовые заметки и видео в облако не отправляются.
class NialCloudEntry {
  const NialCloudEntry({
    required this.id,
    required this.title,
    required this.text,
    required this.date,
    required this.favorite,
    this.photoCount = 0,
    this.hasVoice = false,
    this.hasVideo = false,
  });

  final String id;
  final String title;
  final String text;
  final DateTime date;
  final bool favorite;
  final int photoCount;
  final bool hasVoice;
  final bool hasVideo;

  static const maxTitle = 2000;
  static const maxText = 200000;

  static String _cut(String value, int limit) {
    if (value.length <= limit) return value;
    var end = limit;
    final unit = value.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    return value.substring(0, end);
  }

  bool get truncated => title.length > maxTitle || text.length > maxText;

  /// Короткий отпечаток содержимого: по нему видно, менялась ли запись.
  String get fingerprint {
    final bytes = utf8.encode(
      jsonEncode([
        title,
        text,
        date.toUtc().toIso8601String(),
        favorite,
        photoCount,
        hasVoice,
        hasVideo,
      ]),
    );
    var a = 0x811C9DC5;
    var b = 0x01000193;
    for (final byte in bytes) {
      a = ((a ^ byte) * 16777619) & 0xFFFFFFFF;
      b = ((b + byte) * 2654435761) & 0xFFFFFFFF;
    }
    return '${bytes.length.toRadixString(16)}-'
        '${a.toRadixString(16)}-${b.toRadixString(16)}';
  }

  Map<String, dynamic> toFields(DateTime syncedAt) => {
    'title': {'stringValue': _cut(title, maxTitle)},
    'text': {'stringValue': _cut(text, maxText)},
    'date': {'timestampValue': date.toUtc().toIso8601String()},
    'favorite': {'booleanValue': favorite},
    'photoCount': {'integerValue': '$photoCount'},
    'hasVoice': {'booleanValue': hasVoice},
    'hasVideo': {'booleanValue': hasVideo},
    'truncated': {'booleanValue': truncated},
    'syncedAt': {'timestampValue': syncedAt.toUtc().toIso8601String()},
  };
}

class NialCloudException implements Exception {
  const NialCloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NialCloudReport {
  const NialCloudReport({this.uploaded = 0, this.removed = 0});
  final int uploaded;
  final int removed;
}

class NialCloudStatus {
  const NialCloudStatus({
    this.loaded = false,
    this.enabled = false,
    this.busy = false,
    this.lastSyncAt,
    this.error,
    this.email,
    this.emailVerified = false,
  });
  final bool loaded;
  final bool enabled;
  final bool busy;
  final DateTime? lastSyncAt;
  final String? error;

  /// Почта аккаунта, к которому привязана облачная копия (null — без аккаунта).
  final String? email;
  final bool emailVerified;

  NialCloudStatus copyWith({
    bool? loaded,
    bool? enabled,
    bool? busy,
    DateTime? lastSyncAt,
    bool clearLastSync = false,
    String? error,
    bool clearError = false,
    String? email,
    bool clearEmail = false,
    bool? emailVerified,
  }) => NialCloudStatus(
    loaded: loaded ?? this.loaded,
    enabled: enabled ?? this.enabled,
    busy: busy ?? this.busy,
    lastSyncAt: clearLastSync ? null : lastSyncAt ?? this.lastSyncAt,
    error: clearError ? null : error ?? this.error,
    email: clearEmail ? null : email ?? this.email,
    emailVerified: clearEmail ? false : emailVerified ?? this.emailVerified,
  );
}

/// Что лежит в облаке аккаунта: записи и имя профиля. Используется при входе
/// на новом телефоне, чтобы вернуть тексты записей в дневник.
class NialCloudRestore {
  const NialCloudRestore({this.entries = const [], this.name, this.about});
  final List<NialCloudEntry> entries;
  final String? name;
  final String? about;
}

/// Имя и описание профиля, которые хранятся вместе с облачной копией.
typedef NialCloudProfile = ({String name, String about});

/// Простое хранилище настроек облачной копии (в приложении — SharedPreferences).
abstract class NialCloudStore {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

class _PreferencesCloudStore implements NialCloudStore {
  final _preferences = SharedPreferencesAsync();
  @override
  Future<String?> read(String key) => _preferences.getString(key);
  @override
  Future<void> write(String key, String? value) => value == null
      ? _preferences.remove(key)
      : _preferences.setString(key, value);
}

/// Односторонняя облачная копия текстов дневника в Firebase (Firestore).
/// Телефон — главный источник: записи только отправляются в облако,
/// из облака в приложение ничего не загружается.
class NialCloudSync {
  NialCloudSync({
    http.Client? client,
    NialCloudStore? store,
    this.apiKey = nialCloudApiKey,
    this.projectId = nialCloudProjectId,
    this.keyPrefix = nialCloudKeyPrefix,
    this.profileSnapshot,
    this.debounce = const Duration(seconds: 4),
  }) : _client = client ?? http.Client(),
       _store = store ?? _PreferencesCloudStore();

  final http.Client _client;
  final NialCloudStore _store;
  final String apiKey;
  final String projectId;

  /// Приставка ключей настроек. Личная сборка: 'nial_' (прежние ключи).
  final String keyPrefix;

  /// Профиль, который отправляется вместе с копией (только в публичной сборке).
  final Future<NialCloudProfile?> Function()? profileSnapshot;
  final Duration debounce;

  /// Облако настроено для этой сборки (есть ключ и ID проекта).
  bool get configured => apiKey.isNotEmpty && projectId.isNotEmpty;

  String get _enabledKey => '${keyPrefix}cloud_enabled_v1';
  String get _refreshKey => '${keyPrefix}cloud_refresh_token_v1';
  String get _uidKey => '${keyPrefix}cloud_uid_v1';
  String get _syncedKey => '${keyPrefix}cloud_synced_v1';
  String get _lastSyncKey => '${keyPrefix}cloud_last_sync_v1';
  String get _emailKey => '${keyPrefix}cloud_email_v1';
  String get _verifiedKey => '${keyPrefix}cloud_email_verified_v1';
  String get _profileSentKey => '${keyPrefix}cloud_profile_sent_v1';
  static const _timeout = Duration(seconds: 25);
  static const _maxWrites = 200;
  static const _maxBatchBytes = 4 * 1024 * 1024;
  static final _validId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final status = ValueNotifier<NialCloudStatus>(const NialCloudStatus());

  Future<void> _queue = Future<void>.value();
  Timer? _timer;
  String? _idToken;
  DateTime _idTokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  static bool isValidId(String id) => _validId.hasMatch(id);

  String get _documents => 'projects/$projectId/databases/(default)/documents';

  void _setStatus(NialCloudStatus value) {
    if (!_disposed) status.value = value;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _queue.then((_) => action());
    _queue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  /// Читает сохранённое состояние переключателя и время последней отправки.
  Future<void> load() async {
    try {
      final enabled = configured && await _store.read(_enabledKey) == '1';
      final last = DateTime.tryParse(await _store.read(_lastSyncKey) ?? '');
      final email = await _store.read(_emailKey);
      _setStatus(
        status.value.copyWith(
          loaded: true,
          enabled: enabled,
          lastSyncAt: last,
          clearLastSync: last == null,
          email: email,
          clearEmail: email == null,
          emailVerified: await _store.read(_verifiedKey) == '1',
        ),
      );
    } catch (_) {
      _setStatus(status.value.copyWith(loaded: true, enabled: false));
    }
  }

  Future<void> setEnabled(bool enabled) => _serial(() async {
    if (enabled && !configured) {
      throw const NialCloudException(
        'Облако не настроено в этой сборке приложения.',
      );
    }
    await _store.write(_enabledKey, enabled ? '1' : null);
    if (!enabled) _timer?.cancel();
    _setStatus(status.value.copyWith(enabled: enabled, clearError: true));
  });

  /// Откладывает отправку на несколько секунд, чтобы серия правок
  /// ушла в облако одним запросом. Ошибки не показываются пользователю
  /// всплывающим окном, а остаются в статусе.
  void schedule(List<NialCloudEntry> Function() snapshot) {
    if (_disposed || !status.value.enabled) return;
    _timer?.cancel();
    _timer = Timer(debounce, () {
      if (_disposed || !status.value.enabled) return;
      unawaited(sync(snapshot()).then<void>((_) {}, onError: (_) {}));
    });
  }

  /// Отправляет в облако новые и изменённые записи и удаляет из облака те,
  /// которых больше нет в дневнике.
  Future<NialCloudReport> sync(List<NialCloudEntry> entries) => _serial(
    () async {
      if (!status.value.enabled || !configured) {
        return const NialCloudReport();
      }
      _setStatus(status.value.copyWith(busy: true));
      try {
        final report = await _sync(entries);
        final now = DateTime.now();
        await _store.write(_lastSyncKey, now.toUtc().toIso8601String());
        _setStatus(
          status.value.copyWith(busy: false, lastSyncAt: now, clearError: true),
        );
        return report;
      } catch (error) {
        final failure = _describe(error);
        _setStatus(status.value.copyWith(busy: false, error: failure.message));
        throw failure;
      }
    },
  );

  /// Удаляет облачную копию и анонимный облачный профиль, выключает отправку.
  Future<void> deleteCloudCopy() => _serial(() async {
    _timer?.cancel();
    _setStatus(status.value.copyWith(busy: true));
    try {
      if (await _store.read(_refreshKey) != null) {
        final uid = await _store.read(_uidKey);
        if (uid != null) {
          await _deleteRemote(uid, deleteAccount: true);
        } else {
          await _post(
            _identity('accounts:delete'),
            jsonEncode({'idToken': await _token()}),
            json: true,
          );
        }
      }
      await _clearSession();
      await _clearAccount();
      _setStatus(const NialCloudStatus(loaded: true, enabled: false));
    } catch (error) {
      final failure = _describe(error);
      _setStatus(status.value.copyWith(busy: false, error: failure.message));
      throw failure;
    }
  });

  /// Регистрация по почте: текущий облачный профиль (и уже отправленные
  /// записи) привязывается к почте, идентификатор пользователя не меняется.
  /// Включает облачную копию.
  Future<void> register(String email, String password) => _serial(() async {
    _requireConfigured();
    _setStatus(status.value.copyWith(busy: true, clearError: true));
    try {
      final token = await _token();
      final response = await _post(
        _identity('accounts:signUp'),
        jsonEncode({
          'idToken': token,
          'email': email.trim(),
          'password': password,
          'returnSecureToken': true,
        }),
        json: true,
      );
      if (response.statusCode != 200) throw _authFailure(response);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final idToken = data['idToken'];
      final refreshToken = data['refreshToken'];
      final uid = data['localId'];
      if (idToken is! String || refreshToken is! String || uid is! String) {
        throw const NialCloudException('Облако вернуло некорректный ответ.');
      }
      if (uid != await _store.read(_uidKey)) {
        await _store.write(_syncedKey, null);
      }
      await _saveSession(
        idToken: idToken,
        refreshToken: refreshToken,
        uid: uid,
        expiresIn: data['expiresIn'],
      );
      await _store.write(_emailKey, email.trim());
      await _store.write(_verifiedKey, null);
      await _store.write(_enabledKey, '1');
      try {
        await _sendVerification(idToken);
      } catch (_) {
        // Письмо можно отправить повторно из настроек.
      }
      _setStatus(
        status.value.copyWith(
          busy: false,
          enabled: true,
          email: email.trim(),
          emailVerified: false,
        ),
      );
    } catch (error) {
      final failure = _describe(error);
      _setStatus(status.value.copyWith(busy: false, error: failure.message));
      throw failure;
    }
  });

  /// Вход по почте. Возвращает тексты записей и профиль из облака, чтобы
  /// приложение добавило в дневник недостающие записи. Если до входа на
  /// телефоне была анонимная копия без почты, она удаляется из облака:
  /// записи телефона затем отправятся в аккаунт.
  Future<NialCloudRestore> signIn(String email, String password) => _serial(
    () async {
      _requireConfigured();
      _timer?.cancel();
      _setStatus(status.value.copyWith(busy: true, clearError: true));
      try {
        final response = await _post(
          _identity('accounts:signInWithPassword'),
          jsonEncode({
            'email': email.trim(),
            'password': password,
            'returnSecureToken': true,
          }),
          json: true,
        );
        if (response.statusCode != 200) throw _authFailure(response);
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final idToken = data['idToken'];
        final refreshToken = data['refreshToken'];
        final uid = data['localId'];
        if (idToken is! String || refreshToken is! String || uid is! String) {
          throw const NialCloudException('Облако вернуло некорректный ответ.');
        }
        final oldUid = await _store.read(_uidKey);
        if (oldUid != null &&
            oldUid != uid &&
            await _store.read(_emailKey) == null &&
            await _store.read(_refreshKey) != null) {
          try {
            await _deleteRemote(oldUid, deleteAccount: true);
          } catch (_) {
            // Не мешаем входу, если старую копию удалить не удалось.
          }
        }
        await _clearSession();
        await _saveSession(
          idToken: idToken,
          refreshToken: refreshToken,
          uid: uid,
          expiresIn: data['expiresIn'],
        );
        final verified = await _lookupVerified(idToken);
        await _store.write(_emailKey, email.trim());
        await _store.write(_verifiedKey, verified ? '1' : null);
        await _store.write(_enabledKey, '1');
        final restore = await _download(uid, idToken);
        _setStatus(
          status.value.copyWith(
            busy: false,
            enabled: true,
            email: email.trim(),
            emailVerified: verified,
          ),
        );
        return restore;
      } catch (error) {
        final failure = _describe(error);
        _setStatus(status.value.copyWith(busy: false, error: failure.message));
        throw failure;
      }
    },
  );

  /// Выход из аккаунта: записи на телефоне остаются, копия в облаке тоже,
  /// отправка выключается.
  Future<void> signOut() => _serial(() async {
    _timer?.cancel();
    await _clearSession();
    await _clearAccount();
    _setStatus(const NialCloudStatus(loaded: true, enabled: false));
  });

  /// Повторно отправляет письмо для подтверждения почты.
  Future<void> resendVerification() => _serial(() async {
    try {
      await _sendVerification(await _token());
    } catch (error) {
      throw _describe(error);
    }
  });

  /// Проверяет, подтверждена ли почта (после перехода по ссылке из письма).
  Future<bool> refreshVerification() => _serial(() async {
    try {
      final verified = await _lookupVerified(await _token(force: true));
      await _store.write(_verifiedKey, verified ? '1' : null);
      _setStatus(status.value.copyWith(emailVerified: verified));
      return verified;
    } catch (error) {
      throw _describe(error);
    }
  });

  /// Письмо со ссылкой для смены пароля.
  Future<void> sendPasswordReset(String email) => _serial(() async {
    _requireConfigured();
    try {
      final response = await _post(
        _identity('accounts:sendOobCode'),
        jsonEncode({'requestType': 'PASSWORD_RESET', 'email': email.trim()}),
        json: true,
      );
      if (response.statusCode != 200) throw _authFailure(response);
    } catch (error) {
      throw _describe(error);
    }
  });

  void _requireConfigured() {
    if (!configured) {
      throw const NialCloudException(
        'Облако не настроено в этой сборке приложения.',
      );
    }
  }

  Uri _identity(String method) => Uri.https(
    'identitytoolkit.googleapis.com',
    '/v1/$method',
    {'key': apiKey},
  );

  Future<void> _sendVerification(String idToken) async {
    final response = await _post(
      _identity('accounts:sendOobCode'),
      jsonEncode({'requestType': 'VERIFY_EMAIL', 'idToken': idToken}),
      json: true,
    );
    if (response.statusCode != 200) throw _authFailure(response);
  }

  Future<bool> _lookupVerified(String idToken) async {
    final response = await _post(
      _identity('accounts:lookup'),
      jsonEncode({'idToken': idToken}),
      json: true,
    );
    if (response.statusCode != 200) throw _authFailure(response);
    final users = (jsonDecode(response.body) as Map)['users'];
    if (users is List && users.isNotEmpty && users.first is Map) {
      return (users.first as Map)['emailVerified'] == true;
    }
    return false;
  }

  Future<void> _deleteRemote(String uid, {required bool deleteAccount}) async {
    final token = await _token();
    final names = await _listRemote(uid, token);
    final writes = <Map<String, dynamic>>[
      for (final name in names) {'delete': name},
      {'delete': '$_documents/users/$uid'},
    ];
    for (var i = 0; i < writes.length; i += _maxWrites) {
      final end = i + _maxWrites > writes.length
          ? writes.length
          : i + _maxWrites;
      await _commit(writes.sublist(i, end));
    }
    if (deleteAccount) {
      await _post(
        _identity('accounts:delete'),
        jsonEncode({'idToken': token}),
        json: true,
      );
    }
  }

  Future<NialCloudRestore> _download(String uid, String token) async {
    final result = <NialCloudEntry>[];
    String? pageToken;
    do {
      final response = await _client
          .get(
            Uri.https(
              'firestore.googleapis.com',
              '/v1/$_documents/users/$uid/entries',
              {'pageSize': '300', 'pageToken': ?pageToken},
            ),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (response.statusCode != 200) throw _httpFailure(response);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      for (final document in data['documents'] as List? ?? const []) {
        final entry = _parseEntry(document);
        if (entry != null) result.add(entry);
      }
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);

    String? name;
    String? about;
    final meta = await _client
        .get(
          Uri.https('firestore.googleapis.com', '/v1/$_documents/users/$uid'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(_timeout);
    if (meta.statusCode == 200) {
      final fields = (jsonDecode(meta.body) as Map)['fields'];
      if (fields is Map) {
        name = (fields['name'] as Map?)?['stringValue'] as String?;
        about = (fields['about'] as Map?)?['stringValue'] as String?;
      }
    } else if (meta.statusCode != 404) {
      throw _httpFailure(meta);
    }
    return NialCloudRestore(entries: result, name: name, about: about);
  }

  static NialCloudEntry? _parseEntry(Object? document) {
    if (document is! Map) return null;
    final name = document['name'];
    final fields = document['fields'];
    if (name is! String || fields is! Map) return null;
    final id = name.split('/').last;
    if (!isValidId(id)) return null;
    String? str(String key) => (fields[key] as Map?)?['stringValue'] as String?;
    bool flag(String key) => (fields[key] as Map?)?['booleanValue'] == true;
    final date = DateTime.tryParse(
      (fields['date'] as Map?)?['timestampValue'] as String? ?? '',
    );
    final title = str('title');
    final text = str('text');
    if (title == null || text == null || date == null) return null;
    return NialCloudEntry(
      id: id,
      title: title,
      text: text,
      date: date.toLocal(),
      favorite: flag('favorite'),
      photoCount:
          int.tryParse('${(fields['photoCount'] as Map?)?['integerValue']}') ??
          0,
      hasVoice: flag('hasVoice'),
      hasVideo: flag('hasVideo'),
    );
  }

  NialCloudException _authFailure(http.Response response) {
    final body = response.body;
    const known = {
      'EMAIL_EXISTS': 'Эта почта уже зарегистрирована. Войди в аккаунт.',
      'INVALID_LOGIN_CREDENTIALS': 'Неверная почта или пароль.',
      'INVALID_PASSWORD': 'Неверная почта или пароль.',
      'EMAIL_NOT_FOUND': 'Неверная почта или пароль.',
      'INVALID_EMAIL': 'Проверь адрес почты.',
      'MISSING_PASSWORD': 'Введи пароль.',
      'WEAK_PASSWORD': 'Пароль слишком простой: нужно минимум 6 символов.',
      'TOO_MANY_ATTEMPTS_TRY_LATER': 'Слишком много попыток. Попробуй позже.',
      'USER_DISABLED': 'Этот аккаунт отключён.',
      'OPERATION_NOT_ALLOWED': 'Вход по почте пока недоступен.',
      'CREDENTIAL_TOO_OLD_LOGIN_AGAIN': 'Войди в аккаунт заново.',
      'PROVIDER_ALREADY_LINKED': 'К этому облаку уже привязана почта.',
    };
    for (final item in known.entries) {
      if (body.contains(item.key)) return NialCloudException(item.value);
    }
    return _httpFailure(response);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client.close();
    status.dispose();
  }

  Future<NialCloudReport> _sync(List<NialCloudEntry> entries) async {
    final seen = <String>{};
    for (final entry in entries) {
      if (!isValidId(entry.id) || !seen.add(entry.id)) {
        throw const NialCloudException(
          'У записей повреждены идентификаторы. Облачная копия не изменена.',
        );
      }
    }
    await _token();
    final uid = await _store.read(_uidKey);
    if (uid == null) {
      throw const NialCloudException('Не удалось войти в облако.');
    }
    final synced = await _readSynced();
    final now = DateTime.now();
    final base = '$_documents/users/$uid';

    final pending = <(Map<String, dynamic>, String, String?)>[];
    for (final entry in entries) {
      final fingerprint = entry.fingerprint;
      if (synced[entry.id] == fingerprint) continue;
      pending.add((
        {
          'update': {
            'name': '$base/entries/${entry.id}',
            'fields': entry.toFields(now),
          },
        },
        entry.id,
        fingerprint,
      ));
    }
    final uploaded = pending.length;
    final removedIds = synced.keys.where((id) => !seen.contains(id)).toList();
    for (final id in removedIds) {
      pending.add(({'delete': '$base/entries/$id'}, id, null));
    }
    final profile = await _readProfile();
    final profileJson = profile == null
        ? null
        : jsonEncode([profile.name, profile.about]);
    final profileChanged =
        profileJson != null &&
        profileJson != await _store.read(_profileSentKey);
    if (pending.isEmpty && !profileChanged) return const NialCloudReport();

    Map<String, dynamic> meta() => {
      'update': {
        'name': base,
        'fields': {
          'app': {'stringValue': 'nial_diary'},
          'entryCount': {'integerValue': '${entries.length}'},
          'updatedAt': {'timestampValue': now.toUtc().toIso8601String()},
          if (profile != null) ...{
            'name': {'stringValue': profile.name},
            'about': {'stringValue': profile.about},
          },
        },
      },
    };

    if (pending.isEmpty) {
      await _commit([meta()]);
      await _store.write(_profileSentKey, profileJson);
      return const NialCloudReport();
    }

    var index = 0;
    while (index < pending.length) {
      final batch = <(Map<String, dynamic>, String, String?)>[];
      var bytes = 0;
      while (index < pending.length && batch.length < _maxWrites) {
        final size = utf8.encode(jsonEncode(pending[index].$1)).length;
        if (batch.isNotEmpty && bytes + size > _maxBatchBytes) break;
        batch.add(pending[index]);
        bytes += size;
        index++;
      }
      await _commit([for (final item in batch) item.$1, meta()]);
      for (final item in batch) {
        if (item.$3 == null) {
          synced.remove(item.$2);
        } else {
          synced[item.$2] = item.$3!;
        }
      }
      await _store.write(_syncedKey, jsonEncode(synced));
    }
    if (profileJson != null) await _store.write(_profileSentKey, profileJson);
    return NialCloudReport(uploaded: uploaded, removed: removedIds.length);
  }

  Future<Map<String, String>> _readSynced() async {
    final raw = await _store.read(_syncedKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final item in decoded.entries)
          if (item.key is String && item.value is String)
            item.key as String: item.value as String,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> _clearSession() async {
    _idToken = null;
    _idTokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);
    await _store.write(_refreshKey, null);
    await _store.write(_uidKey, null);
    await _store.write(_syncedKey, null);
    await _store.write(_profileSentKey, null);
  }

  Future<void> _clearAccount() async {
    await _store.write(_enabledKey, null);
    await _store.write(_lastSyncKey, null);
    await _store.write(_emailKey, null);
    await _store.write(_verifiedKey, null);
  }

  Future<NialCloudProfile?> _readProfile() async {
    final snapshot = profileSnapshot;
    if (snapshot == null) return null;
    try {
      final profile = await snapshot();
      if (profile == null) return null;
      return (
        name: NialCloudEntry._cut(profile.name, 60),
        about: NialCloudEntry._cut(profile.about, 160),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveSession({
    required String idToken,
    required String refreshToken,
    required String uid,
    required Object? expiresIn,
  }) async {
    final seconds = int.tryParse('$expiresIn') ?? 3600;
    await _store.write(_refreshKey, refreshToken);
    await _store.write(_uidKey, uid);
    _idToken = idToken;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: seconds - 120));
  }

  Future<String> _token({bool force = false}) async {
    final cached = _idToken;
    if (!force && cached != null && DateTime.now().isBefore(_idTokenExpiry)) {
      return cached;
    }
    final refresh = await _store.read(_refreshKey);
    if (refresh != null) {
      final response = await _post(
        Uri.https('securetoken.googleapis.com', '/v1/token', {'key': apiKey}),
        {'grant_type': 'refresh_token', 'refresh_token': refresh},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final idToken = data['id_token'];
        final nextRefresh = data['refresh_token'];
        final uid = data['user_id'];
        if (idToken is! String || nextRefresh is! String || uid is! String) {
          throw const NialCloudException('Облако вернуло некорректный ответ.');
        }
        final knownUid = await _store.read(_uidKey);
        if (knownUid != null && knownUid != uid) {
          await _store.write(_syncedKey, null);
        }
        await _saveSession(
          idToken: idToken,
          refreshToken: nextRefresh,
          uid: uid,
          expiresIn: data['expires_in'],
        );
        return idToken;
      }
      const lost = ['TOKEN_EXPIRED', 'USER_NOT_FOUND', 'INVALID_REFRESH_TOKEN'];
      if (response.statusCode == 400 && lost.any(response.body.contains)) {
        if (await _store.read(_emailKey) != null) {
          // Аккаунт с почтой нельзя молча заменить анонимным: просим войти.
          _timer?.cancel();
          await _clearSession();
          await _clearAccount();
          _setStatus(const NialCloudStatus(loaded: true, enabled: false));
          throw const NialCloudException(
            'Вход в аккаунт устарел. Войди по почте снова.',
          );
        }
        // Облачный профиль больше не существует: начинаем копию заново.
        await _clearSession();
      } else {
        throw _httpFailure(response);
      }
    }
    final response = await _post(
      Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signUp', {
        'key': apiKey,
      }),
      jsonEncode({'returnSecureToken': true}),
      json: true,
    );
    if (response.statusCode != 200) throw _httpFailure(response);
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final idToken = data['idToken'];
    final refreshToken = data['refreshToken'];
    final uid = data['localId'];
    if (idToken is! String || refreshToken is! String || uid is! String) {
      throw const NialCloudException('Облако вернуло некорректный ответ.');
    }
    await _store.write(_syncedKey, null);
    await _saveSession(
      idToken: idToken,
      refreshToken: refreshToken,
      uid: uid,
      expiresIn: data['expiresIn'],
    );
    return idToken;
  }

  Future<List<String>> _listRemote(String uid, String token) async {
    final names = <String>[];
    String? pageToken;
    do {
      final response = await _client
          .get(
            Uri.https(
              'firestore.googleapis.com',
              '/v1/$_documents/users/$uid/entries',
              {
                'pageSize': '300',
                'mask.fieldPaths': 'favorite',
                'pageToken': ?pageToken,
              },
            ),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(_timeout);
      if (response.statusCode != 200) throw _httpFailure(response);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      for (final document in data['documents'] as List? ?? const []) {
        final name = (document as Map)['name'];
        if (name is String) names.add(name);
      }
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null && pageToken.isNotEmpty);
    return names;
  }

  Future<void> _commit(List<Map<String, dynamic>> writes) async {
    final uri = Uri.https('firestore.googleapis.com', '/v1/$_documents:commit');
    final body = jsonEncode({'writes': writes});
    var response = await _post(uri, body, json: true, token: await _token());
    if (response.statusCode == 401) {
      response = await _post(
        uri,
        body,
        json: true,
        token: await _token(force: true),
      );
    }
    if (response.statusCode != 200) throw _httpFailure(response);
  }

  Future<http.Response> _post(
    Uri uri,
    Object body, {
    bool json = false,
    String? token,
  }) => _client
      .post(
        uri,
        headers: {
          if (json) 'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: body,
      )
      .timeout(_timeout);

  NialCloudException _httpFailure(http.Response response) {
    final code = response.statusCode;
    if (code == 429 || response.body.contains('RESOURCE_EXHAUSTED')) {
      return const NialCloudException(
        'Бесплатный дневной лимит облака исчерпан. Отправка продолжится позже.',
      );
    }
    if (code == 401 || code == 403) {
      return const NialCloudException(
        'Облако отклонило доступ. Попробуй позже.',
      );
    }
    if (code >= 500) {
      return const NialCloudException(
        'Облако временно недоступно. Попробуй позже.',
      );
    }
    return NialCloudException('Облако вернуло ошибку $code.');
  }

  NialCloudException _describe(Object error) {
    if (error is NialCloudException) return error;
    if (error is TimeoutException) {
      return const NialCloudException(
        'Облако не ответило вовремя. Проверь интернет.',
      );
    }
    return const NialCloudException(
      'Нет связи с облаком. Проверь интернет. Записи на телефоне в порядке.',
    );
  }
}
