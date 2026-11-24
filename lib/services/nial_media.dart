import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'nial_profile.dart';

class NialMedia {
  static Directory? _root;
  static const maxArchive = 100 * 1024 * 1024;
  static const maxPhotoVoice = 4 * 1024 * 1024;
  static const maxVideo = 25 * 1024 * 1024;
  static final _name = RegExp(r'^media/[a-f0-9-]{36}\.(png|m4a|mp4)$');

  static Future<void> prepare() async {
    if (_root != null) return;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/nial_media_v1');
    await Directory('${root.path}/media').create(recursive: true);
    _root = root;
  }

  static bool isRef(String value) => _name.hasMatch(value);
  static File file(String ref) {
    if (!isRef(ref) || _root == null) {
      throw const FormatException('Invalid media reference');
    }
    return File('${_root!.path}/$ref');
  }

  static Uint8List read(String value) =>
      isRef(value) ? file(value).readAsBytesSync() : base64Decode(value);

  static Future<String> store(Uint8List bytes, String extension) async {
    await prepare();
    final cap = extension == 'mp4' ? maxVideo : maxPhotoVoice;
    if (!['png', 'm4a', 'mp4'].contains(extension) ||
        bytes.isEmpty ||
        bytes.length > cap) {
      throw const FormatException('Media too large or invalid');
    }
    final ref = 'media/${const Uuid().v4()}.$extension';
    final target = file(ref);
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    return ref;
  }

  static Future<String> migratePayload(String payload) async {
    await prepare();
    final decoded = jsonDecode(payload);
    if (decoded is! List || decoded.length > 20000) {
      throw const FormatException('Invalid entries');
    }
    var changed = false;
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid entry');
      }
      final photos = item['photos'];
      if (photos != null) {
        if (photos is! List || photos.length > 6) {
          throw const FormatException('Invalid photos');
        }
        for (var i = 0; i < photos.length; i++) {
          final value = photos[i];
          if (value is! String) throw const FormatException('Invalid photo');
          if (!isRef(value)) {
            if (value.length > 5592408) {
              throw const FormatException('Photo too large');
            }
            photos[i] = await store(base64Decode(value), 'png');
            changed = true;
          } else if (!await file(value).exists()) {
            throw const FormatException('Missing photo');
          }
        }
      }
      final voice = item['voice'];
      if (voice != null) {
        if (voice is! String) throw const FormatException('Invalid voice');
        if (!isRef(voice)) {
          if (voice.length > 5592408) {
            throw const FormatException('Voice too large');
          }
          item['voice'] = await store(base64Decode(voice), 'm4a');
          changed = true;
        } else if (!await file(voice).exists()) {
          throw const FormatException('Missing voice');
        }
      }
    }
    return changed ? jsonEncode(decoded) : payload;
  }

  static Set<String> references(List entries) {
    final result = <String>{};
    if (entries.length > 20000) throw const FormatException('Too many entries');
    for (final item in entries) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid entry');
      }
      final photos = item['photos'] ?? [];
      if (photos is! List || photos.length > 6) {
        throw const FormatException('Invalid photos');
      }
      for (final ref in photos) {
        if (ref is! String || !isRef(ref) || !ref.endsWith('.png')) {
          throw const FormatException('Invalid photo');
        }
        result.add(ref);
      }
      for (final key in ['voice', 'video']) {
        final ref = item[key];
        if (ref == null) continue;
        final ext = key == 'voice' ? '.m4a' : '.mp4';
        if (ref is! String || !isRef(ref) || !ref.endsWith(ext)) {
          throw const FormatException('Invalid attachment');
        }
        result.add(ref);
      }
    }
    return result;
  }

  static Future<Uint8List> exportZip(String payload, {Map<String, dynamic>? profile}) async {
    final checkedProfile = NialProfile.fromJson(profile ?? (const NialProfile()).toJson());
    final entries = jsonDecode(await migratePayload(payload)) as List;
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'nial_diary_backup',
        'version': 5,
        'profile': checkedProfile.toJson(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'entries': entries,
      }),
    );
    if (manifest.length > 8 * 1024 * 1024) {
      throw const FormatException('Metadata too large');
    }
    var total = manifest.length;
    final archive = Archive()
      ..addFile(
        ArchiveFile.noCompress('diary.json', manifest.length, manifest),
      );
    final refs = references(entries);
    if (refs.length > 4999) throw const FormatException('Too many attachments');
    for (final ref in refs) {
      final source = file(ref);
      final length = await source.length();
      final cap = ref.endsWith('.mp4') ? maxVideo : maxPhotoVoice;
      if (length <= 0 ||
          length > cap ||
          total + length > maxArchive - 1024 * 1024) {
        throw const FormatException('Backup exceeds size limit');
      }
      total += length;
      archive.addFile(
        ArchiveFile.noCompress(ref, length, await source.readAsBytes()),
      );
    }
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    if (zip.length > maxArchive) {
      throw const FormatException('Backup too large');
    }
    return zip;
  }

  static Future<String> unpack(Uint8List bytes) async {
    if (bytes.length > maxArchive) {
      throw const FormatException('Backup too large');
    }
    if (bytes.length < 4 || bytes[0] != 80 || bytes[1] != 75) {
      final text = utf8.decode(bytes);
      final decoded = jsonDecode(text);
      if (decoded is! Map || ![1, 2, 3].contains(decoded['version'])) {
        throw const FormatException('Not a legacy backup');
      }
      if (decoded['entries'] is! List) {
        throw const FormatException('Invalid legacy entries');
      }
      decoded['entries'] = jsonDecode(
        await migratePayload(jsonEncode(decoded['entries'])),
      );
      return jsonEncode(decoded);
    }
    // Inspect paths and declared sizes before asking the decoder to verify contents.
    final preview = ZipDecoder().decodeBytes(
      bytes,
      verify: false,
      throwOnError: true,
    );
    if (preview.length > 5000) throw const FormatException('Too many files');
    final names = <String>{};
    var total = 0;
    for (final entry in preview) {
      if (!entry.isFile ||
          entry.isSymbolicLink ||
          !names.add(entry.name) ||
          (entry.name != 'diary.json' && !isRef(entry.name))) {
        throw const FormatException('Unsafe archive member');
      }
      final cap = entry.name == 'diary.json'
          ? 8 * 1024 * 1024
          : entry.name.endsWith('.mp4')
          ? maxVideo
          : maxPhotoVoice;
      if (entry.size < 0 || entry.size > cap) {
        throw const FormatException('Archive member too large');
      }
      total += entry.size;
      if (total > maxArchive) {
        throw const FormatException('Expanded backup too large');
      }
    }
    final archive = ZipDecoder().decodeBytes(
      bytes,
      verify: true,
      throwOnError: true,
    );
    final members = <String, ArchiveFile>{
      for (final entry in archive) entry.name: entry,
    };
    final manifest = members['diary.json'];
    if (manifest == null) throw const FormatException('Missing diary.json');
    final decoded = jsonDecode(utf8.decode(manifest.content));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'nial_diary_backup' ||
        ![4, 5].contains(decoded['version']) ||
        decoded['entries'] is! List) {
      throw const FormatException('Invalid archive manifest');
    }
    if (decoded['version'] == 5) {
      NialProfile.fromJson(decoded['profile']);
    }
    final entries = decoded['entries'] as List;
    final refs = references(entries);
    if (members.length != refs.length + 1 || !refs.every(members.containsKey)) {
      throw const FormatException('Missing or unexpected attachments');
    }
    final replacements = <String, String>{};
    for (final ref in refs) {
      final member = members[ref]!;
      final data = member.content;
      if (data.length != member.size) {
        throw const FormatException('Wrong attachment size');
      }
      replacements[ref] = await store(data, ref.split('.').last);
    }
    for (final item in entries) {
      item['photos'] = (item['photos'] as List? ?? [])
          .map((ref) => replacements[ref]!)
          .toList();
      if (item['voice'] != null) item['voice'] = replacements[item['voice']];
      if (item['video'] != null) item['video'] = replacements[item['video']];
    }
    return jsonEncode(decoded);
  }
}
