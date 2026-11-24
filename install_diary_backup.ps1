$ErrorActionPreference = 'Stop'
$root = 'C:\dev\nial_diary'
$mainPath = Join-Path $root 'lib\main.dart'
$pubPath = Join-Path $root 'pubspec.yaml'
$main = [IO.File]::ReadAllText($mainPath)
$pub = [IO.File]::ReadAllText($pubPath)
function Patch([string]$text, [string]$pattern, [string]$replacement) {
  $hits = [regex]::Matches($text, $pattern)
  if ($hits.Count -ne 1) { throw "Expected 1 match, found $($hits.Count): $pattern. No files saved." }
  $hit = $hits[0]
  return $text.Substring(0, $hit.Index) + $replacement + $text.Substring($hit.Index + $hit.Length)
}
if ($main.Contains('_diaryBackupPanel')) { throw 'Backup feature already present. No files saved.' }
if (!$main.Contains('_useDiaryContext')) { throw 'Diary context missing. No files saved.' }
$methods = @'

  bool _backupBusy = false;
  static const _backupLimit = 10 * 1024 * 1024;

  void _backupNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Uint8List _backupBytes(String payload) {
    if ((jsonDecode(payload) as List).length > 20000) {
      throw const FormatException('В дневнике больше 20 000 записей.');
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 'nial_diary_backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'entries': jsonDecode(payload),
    })));
    if (bytes.length > _backupLimit) {
      throw const FormatException('Копия превышает лимит 10 МиБ.');
    }
    return bytes;
  }

  Future<bool> _saveBackupFile(String payload, String prefix) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final result = await FilePicker.saveFile(
      dialogTitle: 'Сохранить копию дневника',
      fileName: '${prefix}_$stamp.json',
      bytes: _backupBytes(payload),
    );
    return result != null;
  }

  Future<void> _exportDiaryBackup() async {
    if (_backupBusy || _isSending || !_storageReady) return;
    setState(() => _backupBusy = true);
    try {
      await _saveQueue;
      if (!mounted) return;
      final saved = await _saveBackupFile(_encodeDiary(), 'nial_diary');
      if (saved) _backupNotice('Копия сохранена в выбранном месте.');
    } on FormatException catch (error) {
      _backupNotice(error.message);
    } catch (_) {
      _backupNotice('Не удалось сохранить копию. Проверь место сохранения и попробуй снова.');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  List<Entry> _validateDiaryBackup(Uint8List bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != 'nial_diary_backup' ||
        decoded['version'] is! int || decoded['version'] != 1 ||
        decoded['entries'] is! List) {
      throw const FormatException('Это не поддерживаемая копия Nial Dairy.');
    }
    final items = decoded['entries'] as List;
    if (items.length > 20000) {
      throw const FormatException('В копии больше 20 000 записей.');
    }
    return items.map((item) {
      if (item is! Map<String, dynamic> || item['title'] is! String ||
          item['text'] is! String || item['date'] is! String ||
          item['favorite'] is! bool) {
        throw const FormatException('В копии найдена некорректная запись.');
      }
      final parsedDate = DateTime.tryParse(item['date'] as String);
      if (parsedDate == null) {
        throw const FormatException('В копии найдена некорректная дата.');
      }
      return Entry(item['title'] as String, item['text'] as String,
        parsedDate, favorite: item['favorite'] as bool);
    }).toList();
  }

  Future<void> _importDiaryBackup() async {
    if (_backupBusy || _isSending || !_storageReady) return;
    setState(() => _backupBusy = true);
    try {
      await _saveQueue;
      if (!mounted) return;
      final selected = await FilePicker.pickFile(dialogTitle: 'Выбрать копию дневника');
      if (selected == null) return;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in selected.readAsByteStream()) {
        if (builder.length + chunk.length > _backupLimit) {
          throw const FormatException('Файл больше 10 МиБ. Восстановление отменено.');
        }
        builder.add(chunk);
      }
      final restored = _validateDiaryBackup(builder.takeBytes());
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Заменить записи дневника?'),
          content: SingleChildScrollView(child: Text(
            'Сейчас записей: ${entries.length}. В копии: ${restored.length}.\n\n'
            'Текущие записи будут заменены, а не объединены с копией. '
            'Сначала потребуется сохранить текущий дневник в отдельный файл. '
            'Выбери для него новое имя, не перезаписывай исходную копию. '
            'Если отменить сохранение, восстановление не начнётся.\n\n'
            'Беседа и черновик сообщения будут очищены, доступ ассистента к дневнику выключен. '
            'Файлы копий не зашифрованы и содержат тексты записей.',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Сохранить текущие и заменить')),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      final savedCurrent = await _saveBackupFile(_encodeDiary(), 'nial_before_restore');
      if (!savedCurrent) {
        _backupNotice('Восстановление отменено: текущая копия не сохранена.');
        return;
      }
      if (!mounted) return;
      final payload = jsonEncode(restored.map((e) => {
        'title': e.title, 'text': e.text,
        'date': e.date.toIso8601String(), 'favorite': e.favorite,
      }).toList());
      final operation = _saveQueue.then((_) => _diaryStorage.write(payload));
      _saveQueue = operation.then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {});
      await operation;
      if (!mounted) return;
      setState(() {
        entries..clear()..addAll(restored);
        _useDiaryContext = false;
        _chatMessages.clear();
        _messageController.clear();
        _chatError = null;
        _diaryQuery = '';
        _diarySearchController.clear();
        onlyFavorites = false;
      });
      _backupNotice('Восстановлено записей: ${restored.length}. Контекст ассистента выключен.');
    } on FormatException {
      _backupNotice('Файл повреждён, имеет неподдерживаемый формат или превышает лимиты. Дневник не заменён.');
    } catch (_) {
      _backupNotice('Не удалось восстановить дневник. Попробуй снова. Если ошибка повторится, сохрани файл копии.');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Widget _diaryBackupPanel() => box(Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Резервная копия', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      Text('Названия, тексты, даты и избранное. Без чата, ключа ИИ и разрешения на контекст. '
        'JSON-файл не зашифрован: храни его в надёжном месте. Лимит: 10 МиБ и 20 000 записей.', style: small),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _isSending || !_storageReady || _backupBusy ? null : _exportDiaryBackup,
        icon: const Icon(Icons.save_alt_rounded), label: const Text('Сохранить копию')),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _isSending || !_storageReady || _backupBusy ? null : _importDiaryBackup,
        icon: const Icon(Icons.restore_rounded), label: const Text('Восстановить из файла')),
    ],
  ));

'@
$main = Patch $main 'class\s+_HomeState\s+extends\s+State<Home>\s*\{' ('class _HomeState extends State<Home> {' + "`n" + $methods)
$main = "import 'dart:typed_data';`nimport 'package:file_picker/file_picker.dart';`n" + $main
$main = Patch $main 'Future<void>\s+_saveDiary\(\)\s+async\s*\{' "Future<void> _saveDiary() async {`n    if (_backupBusy) return;"
$main = Patch $main 'Widget\s+settings\(\)\s*=>\s*Column\(\s*crossAxisAlignment:\s*CrossAxisAlignment.stretch,\s*children:\s*\[' @'
Widget settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _diaryBackupPanel(),
      const SizedBox(height: 16),
'@
$busy = @'
    if (_backupBusy) {
      return const PopScope(
        canPop: false,
        child: Scaffold(body: Center(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [CircularProgressIndicator(), SizedBox(height: 16),
            Text('Работа с резервной копией…')],
        ))),
      );
    }

'@
$main = Patch $main '    if \(!_storageReady\) \{' ($busy + "`n    if (!_storageReady) {")
if ($pub -match '(?m)^\s+file_picker\s*:') { throw 'file_picker dependency already exists; review its version before installation. No files saved.' }
$pub = Patch $pub '(?m)^  shared_preferences:[^\r\n]*' '$0_PLACEHOLDER'
# Literal insertion keeps PowerShell and regex replacement expansion out of source code.
$originalPub = [IO.File]::ReadAllText($pubPath)
$dep = [regex]::Match($originalPub, '(?m)^  shared_preferences:[^\r\n]*').Value
$pub = $pub.Replace('$0_PLACEHOLDER', ($dep + "`n  file_picker: 13.3.3"))
$backup = Join-Path $root ('backups\before_backup_feature_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Copy-Item -LiteralPath $mainPath -Destination (Join-Path $backup 'main.dart.bak')
Copy-Item -LiteralPath $pubPath -Destination (Join-Path $backup 'pubspec.yaml.bak')
$utf8 = [Text.UTF8Encoding]::new($false)
try {
  [IO.File]::WriteAllText($mainPath, $main, $utf8)
  [IO.File]::WriteAllText($pubPath, $pub, $utf8)
} catch {
  Copy-Item -LiteralPath (Join-Path $backup 'main.dart.bak') -Destination $mainPath -Force
  Copy-Item -LiteralPath (Join-Path $backup 'pubspec.yaml.bak') -Destination $pubPath -Force
  throw
}
Write-Host 'SUCCESS: backup feature installed. Run flutter pub get, dart format, flutter analyze.'
Write-Host "Source backups: $backup"
