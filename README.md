# nial_diary

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Публичная сборка (для других пользователей)

Один код, две редакции:

- личная (по умолчанию): `flutter build apk --release` — облако `nial-diary-43dfa`, ID приложения `com.nial.nial_diary`;
- публичная: `flutter build apk --release --dart-define=NIAL_EDITION=public` — облако `nial-diary-public`, ID приложения `com.nial.nial_diary.community`.

Публичная сборка ставится рядом с личной, хранит настройки облака под своими ключами и никогда не обращается к личному проекту. В публичном проекте вход только анонимный, читательских аккаунтов нет, правила лежат в `firestore.public.rules`. В публичной сборке есть аккаунт по почте (Настройки → Аккаунт): регистрация привязывает почту к облачной копии, вход на другом телефоне возвращает тексты записей и имя профиля, есть подтверждение почты, сброс пароля и выход. Фото, аудио и видео в облако не попадают и не восстанавливаются; шифрования на устройстве нет. В личной сборке аккаунта нет, облако работает как раньше.
