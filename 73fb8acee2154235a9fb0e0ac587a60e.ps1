$ErrorActionPreference = 'Stop'
$target = 'C:\dev\nial_diary\lib\services\diary_storage.dart'
if (Test-Path -LiteralPath $target) {
  throw 'diary_storage.dart already exists. No files overwritten.'
}
$parent = Split-Path -Parent $target
if (!(Test-Path -LiteralPath $parent -PathType Container)) {
  throw 'services folder missing. No changes made.'
}
$encoded = @'
aW1wb3J0ICdwYWNrYWdlOnBhdGgvcGF0aC5kYXJ0JyBhcyBwOwppbXBvcnQgJ3BhY2thZ2U6c3FmbGl0ZS9zcWZsaXRlLmRhcnQnOwoKY2xhc3MgRGlhcnlTdG9yYWdlIHsKICBzdGF0aWMgRnV0dXJlPERhdGFiYXNlPj8gX2RhdGFiYXNlRnV0dXJlOwoKICBGdXR1cmU8RGF0YWJhc2U+IF9kYXRhYmFzZSgpIGFzeW5jIHsKICAgIGZpbmFsIGV4aXN0aW5nID0gX2RhdGFiYXNlRnV0dXJlOwogICAgaWYgKGV4aXN0aW5nICE9IG51bGwpIHsKICAgICAgcmV0dXJuIGV4aXN0aW5nOwogICAgfQoKICAgIGZpbmFsIG9wZW5pbmcgPSBfb3BlbkRhdGFiYXNlKCk7CiAgICBfZGF0YWJhc2VGdXR1cmUgPSBvcGVuaW5nOwoKICAgIHRyeSB7CiAgICAgIHJldHVybiBhd2FpdCBvcGVuaW5nOwogICAgfSBjYXRjaCAoXykgewogICAgICBfZGF0YWJhc2VGdXR1cmUgPSBudWxsOwogICAgICByZXRocm93OwogICAgfQogIH0KCiAgRnV0dXJlPERhdGFiYXNlPiBfb3BlbkRhdGFiYXNlKCkgYXN5bmMgewogICAgZmluYWwgZGlyZWN0b3J5ID0gYXdhaXQgZ2V0RGF0YWJhc2VzUGF0aCgpOwoKICAgIHJldHVybiBvcGVuRGF0YWJhc2UoCiAgICAgIHAuam9pbihkaXJlY3RvcnksICduaWFsX2RpYXJ5LnNxbGl0ZScpLAogICAgICB2ZXJzaW9uOiAxLAogICAgICBvbkNyZWF0ZTogKGRiLCB2ZXJzaW9uKSBhc3luYyB7CiAgICAgICAgYXdhaXQgZGIuZXhlY3V0ZSgKICAgICAgICAgICdDUkVBVEUgVEFCTEUgZGlhcnlfc25hcHNob3QgKCcKICAgICAgICAgICdpZCBJTlRFR0VSIFBSSU1BUlkgS0VZLCAnCiAgICAgICAgICAncGF5bG9hZCBURVhUIE5PVCBOVUxMJwogICAgICAgICAgJyknLAogICAgICAgICk7CiAgICAgIH0sCiAgICApOwogIH0KCiAgRnV0dXJlPFN0cmluZz8+IHJlYWQoKSBhc3luYyB7CiAgICBmaW5hbCBkYiA9IGF3YWl0IF9kYXRhYmFzZSgpOwoKICAgIGZpbmFsIHJvd3MgPSBhd2FpdCBkYi5xdWVyeSgKICAgICAgJ2RpYXJ5X3NuYXBzaG90JywKICAgICAgY29sdW1uczogWydwYXlsb2FkJ10sCiAgICAgIHdoZXJlOiAnaWQgPSA/JywKICAgICAgd2hlcmVBcmdzOiBbMV0sCiAgICAgIGxpbWl0OiAxLAogICAgKTsKCiAgICBpZiAocm93cy5pc0VtcHR5KSB7CiAgICAgIHJldHVybiBudWxsOwogICAgfQoKICAgIHJldHVybiByb3dzLmZpcnN0WydwYXlsb2FkJ10gYXMgU3RyaW5nOwogIH0KCiAgRnV0dXJlPHZvaWQ+IHdyaXRlKFN0cmluZyBwYXlsb2FkKSBhc3luYyB7CiAgICBmaW5hbCBkYiA9IGF3YWl0IF9kYXRhYmFzZSgpOwoKICAgIGF3YWl0IGRiLnRyYW5zYWN0aW9uKCh0cmFuc2FjdGlvbikgYXN5bmMgewogICAgICBhd2FpdCB0cmFuc2FjdGlvbi5pbnNlcnQoJ2RpYXJ5X3NuYXBzaG90JywgewogICAgICAgICdpZCc6IDEsCiAgICAgICAgJ3BheWxvYWQnOiBwYXlsb2FkLAogICAgICB9LCBjb25mbGljdEFsZ29yaXRobTogQ29uZmxpY3RBbGdvcml0aG0ucmVwbGFjZSk7CiAgICB9KTsKICB9Cn0K
'@
$bytes = [Convert]::FromBase64String($encoded.Trim())
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
finally { $sha.Dispose() }
if ($hash -ne 'A59B659C8DFAD9704E88DD2B37DBE19B0803C3C5356B491F7EA32E9E4731A51D') { throw 'Recovery checksum failed. No changes made.' }
$stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
Write-Host 'SUCCESS: uploaded diary_storage.dart restored. Database and other files were NOT modified.'
Get-Item -LiteralPath $target | Select-Object FullName, Length
Write-Host 'Checking required project files:'
@(
  'lib\main.dart',
  'lib\services\diary_storage.dart',
  'lib\services\gigachat_service.dart',
  'lib\services\ai_config.dart',
  'pubspec.yaml',
  'android\app\src\main\AndroidManifest.xml'
) | ForEach-Object {
  $full = Join-Path 'C:\dev\nial_diary' $_
  [PSCustomObject]@{ File = $_; Exists = (Test-Path -LiteralPath $full -PathType Leaf) }
} | Format-Table -AutoSize
