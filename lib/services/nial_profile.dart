import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';

class NialProfile {
  const NialProfile({this.name = '', this.about = '', this.avatar});
  final String name;
  final String about;
  final String? avatar;
  String get displayName => name.isEmpty ? 'Мой дневник' : name;
  Uint8List? get avatarBytes => avatar == null ? null : base64Decode(avatar!);
  Map<String, dynamic> toJson() => {'name': name, 'about': about, 'avatar': avatar};

  factory NialProfile.fromJson(dynamic value) {
    if (value is! Map || value['name'] is! String || value['about'] is! String) {
      throw const FormatException('Некорректный профиль');
    }
    final name = value['name'] as String;
    final about = value['about'] as String;
    final avatar = value['avatar'];
    if (name.length > 60 || about.length > 160 ||
        (avatar != null && (avatar is! String || avatar.length > 700000))) {
      throw const FormatException('Профиль превышает допустимый размер');
    }
    if (avatar != null) {
      final bytes = base64Decode(avatar as String);
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      if (bytes.length < 33 || bytes.length > 512 * 1024) {
        throw const FormatException('Некорректный аватар');
      }
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) throw const FormatException('Аватар должен быть PNG');
      }
      final header = ByteData.sublistView(bytes);
      if (header.getUint32(8) != 13 || header.getUint32(12) != 0x49484452 ||
          header.getUint32(16) == 0 || header.getUint32(16) > 256 ||
          header.getUint32(20) == 0 || header.getUint32(20) > 256) {
        throw const FormatException('Некорректный размер аватара');
      }
    }
    return NialProfile(name: name.trim(), about: about.trim(), avatar: avatar as String?);
  }
}

class NialProfileStore {
  static const _key = 'nial_local_profile_v1';
  static final _preferences = SharedPreferencesAsync();
  static Future<NialProfile> read() async {
    final raw = await _preferences.getString(_key);
    return raw == null ? const NialProfile() : NialProfile.fromJson(jsonDecode(raw));
  }
  static Future<void> save(NialProfile profile) async {
    final checked = NialProfile.fromJson(profile.toJson());
    await _preferences.setString(_key, jsonEncode(checked.toJson()));
  }
}
