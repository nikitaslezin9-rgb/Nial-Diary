import 'package:material_ui/material_ui.dart';

import 'nial_cloud.dart';

/// Блок «Облачная копия» в настройках: переключатель, статус и кнопки.
class NialCloudPanel extends StatelessWidget {
  const NialCloudPanel({
    super.key,
    required this.cloud,
    required this.snapshot,
    required this.locked,
  });

  final NialCloudSync cloud;
  final List<NialCloudEntry> Function() snapshot;
  final bool locked;

  void _notice(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _when(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _syncNow(BuildContext context) async {
    try {
      final report = await cloud.sync(snapshot());
      if (!context.mounted) return;
      _notice(
        context,
        report.uploaded == 0 && report.removed == 0
            ? 'Облачная копия уже актуальна.'
            : 'Отправлено записей: ${report.uploaded}. '
                  'Удалено из облака: ${report.removed}.',
      );
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    }
  }

  Future<void> _toggle(BuildContext context, bool enabled) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          enabled ? 'Включить облачную копию?' : 'Выключить облачную копию?',
        ),
        content: SingleChildScrollView(
          child: Text(
            enabled
                ? 'Названия, тексты, даты и отметки избранного всех записей, '
                      'включая демонстрационные, будут отправляться в облако '
                      'Firebase (Google) через интернет. Фото, голосовые '
                      'заметки и видео остаются только на телефоне.\n\n'
                      'Копия односторонняя: телефон остаётся главным. '
                      'Удалённые в дневнике записи удаляются и из облака. '
                      'Из облака в приложение ничего не загружается, поэтому '
                      'резервные ZIP-копии по-прежнему нужны.'
                : 'Новые изменения больше не будут отправляться. '
                      'Уже отправленная копия останется в облаке, пока ты '
                      'не удалишь её отдельной кнопкой.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(enabled ? 'Включить' : 'Выключить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await cloud.setEnabled(enabled);
    } catch (_) {
      if (context.mounted) {
        _notice(context, 'Не удалось сохранить настройку. Попробуй снова.');
      }
      return;
    }
    if (enabled && context.mounted) await _syncNow(context);
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить облачную копию?'),
        content: const Text(
          'Все записи будут удалены из облака, а отправка выключится. '
          'Записи на телефоне останутся без изменений.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Удалить из облака'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await cloud.deleteCloudCopy();
      if (context.mounted) _notice(context, 'Облачная копия удалена.');
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final small = TextStyle(color: muted, fontSize: 12, height: 1.7);
    return ValueListenableBuilder<NialCloudStatus>(
      valueListenable: cloud.status,
      builder: (context, status, _) {
        final blocked = locked || status.busy || !status.loaded;
        final line = status.busy
            ? 'Отправляем записи…'
            : status.error != null
            ? status.error!
            : !status.enabled
            ? 'Выключена. Записи хранятся только на телефоне.'
            : status.lastSyncAt == null
            ? 'Включена. Записи ещё не отправлялись.'
            : 'Последняя отправка: ${_when(status.lastSyncAt!)}.';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Тексты записей дублируются в облако Firebase. '
              'Фото, аудио и видео не отправляются. '
              'Нужен интернет; без него записи отправятся позже.',
              style: small,
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Отправлять записи в облако'),
              value: status.enabled,
              onChanged: blocked
                  ? null
                  : (value) => _toggle(context, value),
            ),
            Text(
              line,
              style: status.error != null && !status.busy
                  ? small.copyWith(color: Theme.of(context).colorScheme.error)
                  : small,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: blocked || !status.enabled
                  ? null
                  : () => _syncNow(context),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Отправить сейчас'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: blocked ? null : () => _delete(context),
              icon: const Icon(Icons.cloud_off_outlined),
              label: const Text('Удалить копию из облака'),
            ),
          ],
        );
      },
    );
  }
}
