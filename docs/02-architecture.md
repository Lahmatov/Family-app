# Архитектура

```
┌──────────────────────── iPhone ────────────────────────┐
│ SwiftUI views                                          │
│   └── @Observable models (AppModel, BudgetModel, ...)  │
│         └── Services (protocols)                       │
│               ├── Live*  → supabase-swift → HTTPS      │
│               └── InMemory* (UI tests, previews)       │
│ FamilyCore (Swift package): деньги, валюты, бюджет,    │
│   роли, правила подтверждений. Без UI, тестируется на  │
│   Linux и macOS                                        │
│ Keychain: сессия. Face ID: блокировка приложения        │
└──────────────────────────┬─────────────────────────────┘
                           │ JWT (aal2 после 2FA)
┌──────────────────────────▼─────────────────────────────┐
│ Supabase                                               │
│  Auth (GoTrue): пароль + TOTP, подтверждение email      │
│  PostgREST: таблицы/RPC схемы public                    │
│  Postgres: RLS на каждой таблице, SECURITY DEFINER RPC  │
│            для изменений членства, схема private для    │
│            хелперов, append-only audit_log              │
│  Storage: приватный bucket family-files                 │
└────────────────────────────────────────────────────────┘
```

## Принципы

1. **Источник правды о доступе — база.** Каждая таблица под RLS, у ролей API явные `GRANT`, в том числе по колонкам. UI лишь прячет недоступные действия (`MemberRole.can`), но ничего не разрешает.
2. **Изменения членства только через RPC.** `create_family`, `request_action`, `approve_request`, `accept_invitation`, `leave_family` проверяют роль, MFA и инварианты (не остаться без админа) и пишут аудит.
3. **Деньги — целые минорные единицы.** Сумму в базовой валюте считает триггер на сервере по курсу клиента, а `FamilyCore.CurrencyConverter` воспроизводит то же округление, чтобы превью совпадало с сохранённым.
4. **Логика отдельно от UI.** Всё, что можно посчитать, живёт в `FamilyCore` и покрыто тестами на Linux в CI.
5. **Тестируемость.** Сервисы за протоколами; есть in-memory бэкенд для UI-тестов (`-ui-testing`).

## Структура репозитория

```
FamilyCore/          Swift-пакет доменной логики + тесты
ios/                 iOS-приложение (XcodeGen: project.yml)
  FamilyApp/         код приложения
  FamilyAppTests/    unit-тесты
  FamilyAppUITests/  UI/e2e-тесты
supabase/
  config.toml        настройки Auth/Storage (пароли ≥12, TOTP, подтверждение email)
  migrations/        схема, RLS, RPC
  tests/             pgTAP-тесты (безопасность, роли, изоляция)
scripts/db-test.sh   прогон миграций и тестов на чистом Postgres
.github/workflows/   CI: backend, core, ios, security
docs/                эта документация
```

## Модель данных (этап 1)

| Таблица | Назначение | Кто пишет |
|---|---|---|
| `profiles` | имя, язык | сам пользователь (только свои колонки) |
| `families` | семья, базовая валюта | RPC; админ может переименовать |
| `family_members` | роль в семье | только RPC |
| `family_invitations` | приглашение по email | только RPC |
| `approval_requests` | критичные действия, ждущие второго админа | только RPC |
| `audit_log` | журнал | только SECURITY DEFINER-код; неизменяем |
| `categories` | категории (системные с ключом локализации + свои) | взрослые; удаление — админ |
| `transactions` | расходы/доходы | взрослые (свои), админ (чужие неприватные) |
| `budgets` | лимит на месяц по категории или общий | админ |
| `attachments` | связь файла в Storage с сущностью | автор, при условии что видна сама сущность |
