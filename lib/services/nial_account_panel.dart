import 'package:material_ui/material_ui.dart';

import 'nial_cloud.dart';

/// Аккаунт Nial Diary по почте (только в публичной сборке).
/// Почта привязывается к облачной копии: после входа на другом телефоне
/// тексты записей возвращаются в дневник.
class NialAccountPanel extends StatelessWidget {
  const NialAccountPanel({
    super.key,
    required this.cloud,
    required this.locked,
    required this.onRestored,
  });

  final NialCloudSync cloud;
  final bool locked;

  /// Вызывается после входа: приложение добавляет недостающие записи.
  final Future<int> Function(NialCloudRestore restore) onRestored;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  void _notice(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<({String email, String password})?> _askCredentials(
    BuildContext context, {
    required bool register,
  }) {
    final email = TextEditingController();
    final password = TextEditingController();
    final repeat = TextEditingController();
    String? problem;
    var hidden = true;
    return showDialog<({String email, String password})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(register ? 'Регистрация' : 'Вход по почте'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  register
                      ? 'Почта привяжется к облачной копии дневника. '
                            'Тексты записей и имя профиля будут отправляться '
                            'в облако, а на новом телефоне ты сможешь войти '
                            'и вернуть их. Фото, аудио и видео в облако не '
                            'попадают.'
                      : 'После входа тексты записей из облака добавятся в '
                            'дневник. Записи на этом телефоне останутся и '
                            'отправятся в аккаунт. Фото, аудио и видео из '
                            'облака не восстанавливаются.',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Почта'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: password,
                  obscureText: hidden,
                  autofillHints: [
                    register
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  decoration: InputDecoration(
                    labelText: 'Пароль',
                    helperText: register ? 'Минимум 6 символов' : null,
                    suffixIcon: IconButton(
                      tooltip: hidden ? 'Показать пароль' : 'Скрыть пароль',
                      icon: Icon(
                        hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setDialogState(() => hidden = !hidden),
                    ),
                  ),
                ),
                if (register) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: repeat,
                    obscureText: hidden,
                    decoration: const InputDecoration(
                      labelText: 'Повтори пароль',
                    ),
                  ),
                ],
                if (problem != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    problem!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (!register)
              TextButton(
                onPressed: () async {
                  final address = email.text.trim();
                  if (!_emailPattern.hasMatch(address)) {
                    setDialogState(
                      () => problem = 'Введи почту, чтобы сбросить пароль.',
                    );
                    return;
                  }
                  try {
                    await cloud.sendPasswordReset(address);
                    setDialogState(
                      () => problem =
                          'Если такой аккаунт есть, письмо для смены пароля '
                          'уже отправлено на $address.',
                    );
                  } on NialCloudException catch (error) {
                    setDialogState(() => problem = error.message);
                  }
                },
                child: const Text('Забыл пароль'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final address = email.text.trim();
                String? error;
                if (!_emailPattern.hasMatch(address)) {
                  error = 'Проверь адрес почты.';
                } else if (password.text.length < 6) {
                  error = 'Пароль должен быть не короче 6 символов.';
                } else if (register && password.text != repeat.text) {
                  error = 'Пароли не совпадают.';
                }
                if (error != null) {
                  setDialogState(() => problem = error);
                  return;
                }
                Navigator.pop(dialogContext, (
                  email: address,
                  password: password.text,
                ));
              },
              child: Text(register ? 'Зарегистрироваться' : 'Войти'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _register(BuildContext context) async {
    final credentials = await _askCredentials(context, register: true);
    if (credentials == null || !context.mounted) return;
    try {
      await cloud.register(credentials.email, credentials.password);
      if (context.mounted) {
        _notice(
          context,
          'Аккаунт создан. Мы отправили письмо для подтверждения на '
          '${credentials.email}.',
        );
      }
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    }
  }

  Future<void> _signIn(BuildContext context) async {
    final credentials = await _askCredentials(context, register: false);
    if (credentials == null || !context.mounted) return;
    try {
      final restore = await cloud.signIn(
        credentials.email,
        credentials.password,
      );
      final added = await onRestored(restore);
      if (context.mounted) {
        _notice(
          context,
          added == 0
              ? 'Вход выполнен. Новых записей в облаке нет.'
              : 'Вход выполнен. Из облака добавлено записей: $added.',
        );
      }
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    } catch (_) {
      if (context.mounted) {
        _notice(context, 'Вход выполнен, но записи не удалось сохранить.');
      }
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Записи останутся на телефоне, копия останется в облаке. '
          'Новые изменения перестанут отправляться, пока ты снова не войдёшь.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await cloud.signOut();
    if (context.mounted) _notice(context, 'Ты вышел из аккаунта.');
  }

  Future<void> _checkVerification(BuildContext context) async {
    try {
      final verified = await cloud.refreshVerification();
      if (context.mounted) {
        _notice(
          context,
          verified
              ? 'Почта подтверждена.'
              : 'Почта ещё не подтверждена. Открой ссылку из письма.',
        );
      }
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    }
  }

  Future<void> _resend(BuildContext context) async {
    try {
      await cloud.resendVerification();
      if (context.mounted) _notice(context, 'Письмо отправлено ещё раз.');
    } on NialCloudException catch (error) {
      if (context.mounted) _notice(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return ValueListenableBuilder<NialCloudStatus>(
      valueListenable: cloud.status,
      builder: (context, status, _) {
        final blocked = locked || status.busy || !status.loaded;
        final email = status.email;
        if (email == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Без аккаунта дневник хранится только на телефоне. '
                'Аккаунт по почте привязывает к ней облачную копию: на новом '
                'телефоне можно войти и вернуть тексты записей.',
                style: small,
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: blocked ? null : () => _register(context),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text('Зарегистрироваться по почте'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: blocked ? null : () => _signIn(context),
                icon: const Icon(Icons.login_rounded),
                label: const Text('Войти в аккаунт'),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(email),
              subtitle: Text(
                status.emailVerified
                    ? 'Почта подтверждена. Облачная копия привязана к ней.'
                    : 'Почта не подтверждена. Проверь письмо во входящих '
                          'или в спаме.',
              ),
            ),
            if (!status.emailVerified) ...[
              OutlinedButton.icon(
                onPressed: blocked ? null : () => _checkVerification(context),
                icon: const Icon(Icons.mark_email_read_outlined),
                label: const Text('Я подтвердил почту'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: blocked ? null : () => _resend(context),
                child: const Text('Отправить письмо ещё раз'),
              ),
            ],
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: blocked
                  ? null
                  : () async {
                      try {
                        await cloud.sendPasswordReset(email);
                        if (context.mounted) {
                          _notice(
                            context,
                            'Письмо для смены пароля отправлено на $email.',
                          );
                        }
                      } on NialCloudException catch (error) {
                        if (context.mounted) _notice(context, error.message);
                      }
                    },
              icon: const Icon(Icons.lock_reset_rounded),
              label: const Text('Сменить пароль'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: blocked ? null : () => _signOut(context),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Выйти из аккаунта'),
            ),
          ],
        );
      },
    );
  }
}
