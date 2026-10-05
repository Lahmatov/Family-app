# Сервисы и настройки для максимальной безопасности

Принцип: защита держится на архитектуре (RLS, 2FA, шифрование, тесты), а не на секретности кода. Приватный репозиторий убирает лишний риск, но не заменяет остальное. Цены и лимиты сверять с официальными страницами.

## Что меняется из-за приватного репозитория
- **Минуты Actions:** на бесплатном плане 2000 в месяц, macOS считается за 10. iOS-сборка ~15 минут, то есть около 13 прогонов в месяц. Поэтому `ios.yml` запускается только на pull request, на `main` и вручную, и только при изменениях в `ios/**` и `FamilyCore/**`. Альтернатива: self-hosted раннер на Mac mini.
- **Code scanning и push protection от секретов** (GitHub Advanced Security) для приватных платные. Замена: gitleaks (CI и pre-commit) и Semgrep.
- **Защита ветки `main`** на приватных личных репозиториях может требовать GitHub Pro. Проверить.
- **Dependabot** бесплатен: настроен в `.github/dependabot.yml` (Actions и FamilyCore). Пакеты в `ios/project.yml` обновлять вручную.
- Если репозиторий хоть раз был публичным, историю считать прочитанной. Секретов в ней нет (gitleaks по всей истории).

## Чек-лист

### Аккаунты (самое слабое звено)
- [ ] Passkeys или аппаратные ключи (основной и запасной) на GitHub, Supabase, Apple ID и почте. Почта критична: через неё сбрасывается всё.
- [ ] Менеджер паролей (Bitwarden), пароли уникальные
- [ ] Коды восстановления распечатаны и лежат отдельно от телефона
- [ ] Подписанные коммиты, защита ветки `main`

### Код и зависимости
- [x] Actions закреплены на SHA, `permissions: contents: read`
- [x] gitleaks и Semgrep в CI
- [x] Dependabot (`.github/dependabot.yml`)
- [ ] pre-commit с gitleaks: `brew install pre-commit && pre-commit install` (конфиг `.pre-commit-config.yaml` в репозитории)
- [ ] OSV-Scanner по зависимостям раз в неделю

### Supabase
- [x] RLS на всех таблицах, обязательный `aal2`, тесты на обход
- [ ] Запустить Security Advisor и Performance Advisor (Dashboard → Advisors)
- [ ] CAPTCHA (Turnstile или hCaptcha) на регистрации и входе
- [ ] Принудительный SSL, лимиты запросов Auth, проверка в проде, а не только в `config.toml`
- [ ] Защита от утёкших паролей и PITR (Pro)
- [ ] `service_role` только в секретах Edge Functions и CI, никогда в приложении
- [ ] Отдельный staging-проект, миграции сначала туда

### Приложение
- [x] Face ID и экран-заглушка в переключателе, сессия в Keychain только этого устройства
- [x] EXIF и GPS режутся на устройстве
- [ ] Закрепление сертификата (с запасным ключом, иначе можно заблокировать себя)
- [ ] App Attest (нужен Apple Developer)
- [ ] `NSAllowsLocalNetworking` только в Debug

### Проверки
- [x] pgTAP, unit, UI, тесты на iPad
- [ ] MobSF по готовой сборке
- [ ] strix (автоматически) и hoppscotch (вручную) по API staging: IDOR, обход RLS через RPC, фаззинг — `docs/12-pentest-plan.md`
- [ ] sniffnet: приложение ходит только в Supabase, Frankfurter и Apple
- [ ] Frida/objection на устройстве
- [ ] Внешний пентест, если приложением начнут пользоваться вне семьи

### Наблюдение и бэкапы
- [ ] Письмо о входе с нового устройства и о критичных действиях из `audit_log`
- [ ] UptimeRobot, GlitchTip или Sentry с вырезанием данных
- [ ] Ночной `pg_dump`, шифрование `age`, копия в Cloudflare R2 или Backblaze B2 (ЕС), проверка восстановления раз в квартал

### Почта
- [ ] Свой домен, SPF, DKIM, DMARC, SMTP Brevo

## Приоритеты
1. **Сейчас, бесплатно:** приватный репозиторий, passkeys и 2FA везде, pre-commit, Security Advisor, CAPTCHA, защита `main`.
2. **До реального использования:** домен и SMTP, бэкапы с проверкой восстановления, письма о входе, ZAP и MobSF, закрепление сертификата, политика конфиденциальности (`10-gdpr.md`).
3. **Позже:** Supabase Pro, Apple Developer (App Attest, TestFlight, push), внешний пентест.
