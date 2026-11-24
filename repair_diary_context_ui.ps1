$ErrorActionPreference = 'Stop'
$path = 'C:\dev\nial_diary\lib\main.dart'
$servicePath = 'C:\dev\nial_diary\lib\services\gigachat_service.dart'
$source = [IO.File]::ReadAllText($path)
$service = [IO.File]::ReadAllText($servicePath)
if (!$service.Contains('String diaryContext')) { throw 'Service parameter missing. No changes saved.' }
if ($source.Contains('_useDiaryContext')) { throw 'Main already contains context code. No changes saved.' }
function Patch([string]$text, [string]$pattern, [string]$replacement) {
  $hits = [regex]::Matches($text, $pattern)
  if ($hits.Count -ne 1) { throw "Expected 1 match, found $($hits.Count): $pattern. No changes saved." }
  $hit = $hits[0]
  return $text.Substring(0, $hit.Index) + $replacement + $text.Substring($hit.Index + $hit.Length)
}
$methods = @'
class _HomeState extends State<Home> {
  bool _useDiaryContext = false;

  String _buildDiaryContext() {
    final sorted = List<Entry>.from(entries)
      ..sort((a, b) => b.date.compareTo(a.date));
    final encoded = jsonEncode(sorted.map((e) => {
      'date': e.date.toIso8601String(),
      'title': e.title,
      'text': e.text,
    }).toList());
    if (encoded.length <= 24000) return encoded;
    var end = 24000;
    final unit = encoded.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    return '${encoded.substring(0, end)}\n[Контекст обрезан по лимиту объёма.]';
  }

  Future<void> _changeDiaryContext(bool enabled) async {
    if (_isSending || !_storageReady || enabled == _useDiaryContext) return;
    final description = enabled
      ? 'С каждым сообщением в GigaChat будут передаваться даты, названия и тексты записей, включая демонстрационные. Приоритет у новых записей; объём ограничен, текст может обрезаться. Поиск и избранное не ограничивают передачу. Медиа не отправляются. Разрешение действует до полного перезапуска.'
      : 'Записи больше не будут добавляться в новые запросы.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(enabled ? 'Разрешить контекст дневника?' : 'Выключить контекст?'),
        content: SingleChildScrollView(child: Text(
          '$description\n\nТекущая беседа в приложении будет очищена, чтобы история не переносила прежний контекст. Это не удаляет уже переданные данные у провайдера.',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(enabled ? 'Разрешить' : 'Выключить')),
        ],
      ),
    );
    if (!mounted || confirmed != true || _isSending) return;
    setState(() {
      _useDiaryContext = enabled;
      _chatMessages.clear();
      _chatError = null;
    });
  }

'@
$source = Patch $source 'class\s+_HomeState\s+extends\s+State<Home>\s*\{' $methods
$call = @'
final answer = await _aiService.getResponse(
        message,
        history: history,
        diaryContext: _useDiaryContext ? _buildDiaryContext() : '',
      );
'@
$source = Patch $source 'final\s+answer\s*=\s*await\s+_aiService\.getResponse\(\s*message\s*,\s*history\s*:\s*history\s*,?\s*\)\s*;' $call
$widget = @'
box(
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Использовать записи дневника'),
            subtitle: Text(_useDiaryContext
              ? 'Включено: записи отправляются с сообщениями. Приоритет у новых.'
              : 'Выключено: записи не добавляются в запросы.'),
            value: _useDiaryContext,
            onChanged: _isSending || !_storageReady ? null : (value) { _changeDiaryContext(value); },
          ),
          color: _useDiaryContext ? sage : null,
        ),
        const SizedBox(height: 16),
        ..._chatMessages.map(chatBubble),
'@
$source = Patch $source '\.\.\._chatMessages\s*\.map\(chatBubble\)\s*,' $widget
$source = $source.Replace('Записи дневника пока не отправляются.', 'Передача записей включается переключателем ниже.')
$source = $source.Replace('Записи дневника пока не передаются ассистенту.', 'Передача записей включается отдельно во вкладке ассистента.')
$backupDir = 'C:\dev\nial_diary\backups'
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$backup = Join-Path $backupDir ('main_before_ui_context_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.dart.bak')
Copy-Item -LiteralPath $path -Destination $backup
try {
  [IO.File]::WriteAllText($path, $source, [Text.UTF8Encoding]::new($false))
} catch {
  Copy-Item -LiteralPath $backup -Destination $path -Force
  throw
}
Write-Host 'SUCCESS: main.dart updated. Service was NOT modified.'
Select-String -LiteralPath $path -Pattern '_useDiaryContext|diaryContext'
