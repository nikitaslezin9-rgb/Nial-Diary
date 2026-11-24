// Идентификаторы облачных проектов Firebase для Nial Diary.
// Это не секретные данные: доступ к записям ограничивают правила
// безопасности Firestore, а не этот ключ.
//
// Личная сборка (по умолчанию) — проект «Nial Diary» (nial-diary-43dfa).
// Публичная сборка для других пользователей — отдельный проект
// «Nial Diary Public» (nial-diary-public) и собирается с флагом:
//   --dart-define=NIAL_EDITION=public
// Публичная сборка никогда не использует личный проект. В публичном
// проекте нет читательских аккаунтов: вход только анонимный, правила —
// в файле firestore.public.rules.

const nialEdition = String.fromEnvironment(
  'NIAL_EDITION',
  defaultValue: 'personal',
);
const nialIsPublicEdition = nialEdition == 'public';

const _personalApiKey = 'AIzaSyCH59yPHh2TBzeyoZX89hRIa2RWA8--9sA';
const _personalProjectId = 'nial-diary-43dfa';
const _publicApiKey = String.fromEnvironment(
  'NIAL_PUBLIC_API_KEY',
  defaultValue: 'AIzaSyCAtfGh6ycYa089RH6_v85dfxwjpMGVGdQ',
);
const _publicProjectId = String.fromEnvironment(
  'NIAL_PUBLIC_PROJECT_ID',
  defaultValue: 'nial-diary-public',
);

const nialCloudApiKey = nialIsPublicEdition ? _publicApiKey : _personalApiKey;
const nialCloudProjectId = nialIsPublicEdition
    ? _publicProjectId
    : _personalProjectId;

/// Облако доступно, только если для сборки заданы оба идентификатора.
const nialCloudConfigured =
    nialCloudApiKey != '' && nialCloudProjectId != '';

/// Приставка ключей настроек: у личной сборки ключи прежние, у публичной —
/// свои, чтобы облачные сессии разных проектов никогда не смешивались.
const nialCloudKeyPrefix = nialIsPublicEdition ? 'nial_public_' : 'nial_';
