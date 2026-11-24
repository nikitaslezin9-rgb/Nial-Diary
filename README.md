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

Публичная сборка ставится рядом с личной, хранит настройки облака под своими ключами и никогда не обращается к личному проекту. В публичном проекте вход только анонимный, читательских аккаунтов нет, правила лежат в `firestore.public.rules`. Облачная копия — односторонняя отправка текстов, без восстановления и без шифрования на устройстве.
