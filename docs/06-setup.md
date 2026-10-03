# Запуск на Mac

## 1. Инструменты (один раз)
```bash
brew install xcodegen supabase/tap/supabase
# Docker нужен для локального Supabase: Docker Desktop или OrbStack
brew install --cask orbstack
```

## 2. Локальный бэкенд
```bash
cd Family-app
supabase start          # поднимет Postgres, Auth, Storage, Studio; применит миграции
supabase test db        # pgTAP-тесты
supabase status         # покажет API URL и anon key
```
Письма подтверждения при локальном запуске приходят в Inbucket/Mailpit: ссылку покажет `supabase status`.

## 3. Приложение
```bash
cp ios/Config/Secrets.example.xcconfig ios/Config/Secrets.xcconfig
# впишите SUPABASE_URL (http:/$()/127.0.0.1:54321 для симулятора), SUPABASE_ANON_KEY и DEVELOPMENT_TEAM
cd ios && xcodegen && open FamilyApp.xcodeproj
```
- Запуск в симуляторе: ⌘R. Тесты: ⌘U.
- На своём iPhone: в Xcode → Signing выберите свой Apple ID (бесплатный Personal Team подходит для установки себе на 7 дней). Телефону нужен доступ к серверу: локальный IP Mac'а в той же Wi-Fi или Tailscale.
- Режим без бэкенда: в схеме добавьте аргумент запуска `-ui-testing -signed-in`. Включится демо-режим с данными в памяти.

## 4. Демо-данные для UI-тестов
Email `parent@example.com`, пароль `Correct-Horse-1`, код `123456`. Работают **только** в in-memory режиме (Debug + `-ui-testing`).

## Хостинг (решим позже)
| Вариант | Стоимость | Замечания |
|---|---|---|
| Mac mini дома + Tailscale | ~€700 разово + ~€1–2 в месяц электричество | сервер не виден из интернета; заодно self-hosted раннер для iOS CI. Нужен ИБП и бэкапы |
| VPS в ЕС (Hetzner) | ~€5–8 в месяц + бэкапы | стабильно и дёшево, обновления на нас |
| Supabase Cloud Free/Pro | $0 / $25 в месяц | Free засыпает после недели неактивности и даёт 1 ГБ под файлы |

Миграции одинаковые для любого варианта: `supabase db push` (облако) или `psql -f` по порядку (self-host).
