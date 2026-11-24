import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nial_diary/services/nial_profile.dart';

void main() {
  test('empty profile has a display name', () {
    expect(const NialProfile().displayName, 'Мой дневник');
  });
  test('text roundtrip and trimming', () {
    final profile = NialProfile.fromJson({'name': ' Анна ', 'about': ' Мой мир ', 'avatar': null});
    expect(profile.name, 'Анна');
    expect(profile.about, 'Мой мир');
    expect(NialProfile.fromJson(profile.toJson()).name, 'Анна');
  });
  test('invalid profile is rejected', () {
    for (final invalid in [null, [], {}, {'name': 4, 'about': ''}]) {
      expect(() => NialProfile.fromJson(invalid), throwsFormatException);
    }
  });
  test('oversized name and description are rejected', () {
    expect(() => NialProfile.fromJson({'name': 'a' * 61, 'about': ''}), throwsFormatException);
    expect(() => NialProfile.fromJson({'name': '', 'about': 'a' * 161}), throwsFormatException);
  });
  test('small PNG avatar roundtrip', () {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=';
    final profile = NialProfile.fromJson({'name': '', 'about': '', 'avatar': png});
    expect(profile.avatarBytes, base64Decode(png));
  });
  test('non-image avatar is rejected', () {
    expect(() => NialProfile.fromJson({'name': '', 'about': '', 'avatar': base64Encode(List.filled(40, 0))}), throwsFormatException);
  });
  test('oversized avatar is rejected', () {
    expect(() => NialProfile.fromJson({'name': '', 'about': '', 'avatar': 'a' * 700001}), throwsFormatException);
  });
}
