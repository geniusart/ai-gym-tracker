# IronLog -- Спецификация

## 1. Концепция

iOS-приложение для трекинга силовых и кардио-тренировок + sync-сервер:
- **Импорт плана** -- Claude генерирует JSON-план (strength или cycling), загружает на сервер. Приложение синхронизирует автоматически или импортирует вручную
- **Пошаговая силовая тренировка** -- приложение ведет по упражнениям: prescribed вес/повторы, таймер отдыха, техники (drop-сеты, myo-reps, суперсеты, rest-pause)
- **Кардио по сегментам** -- таймер сегмента, целевая зона пульса, опциональный live HR с Apple Watch
- **Синхронизация логов** -- логи автоматически отправляются на сервер. Claude забирает их для анализа прогресса и корректировки плана
- **Краш-репорты** -- неперехваченные исключения и сигналы пишутся на диск и улетают на сервер при следующем запуске

## 2. Scope

### Реализовано

#### Импорт и хранение
- Импорт JSON-плана (буфер обмена / файл / sync с сервера), превью перед подтверждением
- Auto-dispatch по `plan_type`: один и тот же импорт-флоу работает для strength и cycling
- Shared Base Contract: plan_type, plan_id, plan_version, plan_name, schema, created_at
- Schema identification: timestamp в плане + структурная валидация в приложении (per-type schema id)
- Повторный импорт обновляет существующий план
- Несовместимые планы показываются как "not supported" с timestamps схем
- Один план на (plan_type, plan_id) (при обновлении заменяет предыдущий)
- Списки планов в Plans-табе разбиты на секции "Strength" и "Cycling"

#### Силовая тренировка
- Выбор плана: saved -> last used -> первый доступный
- Выбор шаблона -> Active Workout, одно упражнение на экране
- Ввод: вес (кнопки -5/-1/+1/+5 kg), повторы, RIR
- Автозаполнение веса: из плана (per-set) -> из прошлой тренировки -> вручную
- Warmup-сеты с отдельным prescribed весом
- Заметки к упражнению из плана
- Техники: straight, drop_set, myo_reps (с лимитом мини-сетов), rest_pause, superset
- TechniqueFlow -- stateless протокол для управления потоком сетов
- Поддержка нескольких независимых superset-пар в одной группе (a4↔a6, a5↔a9 в одной "Грудь+Спина")
- SetRoadmap -- визуальный список всех сетов с тремя состояниями
- Таймер отдыха с вибрацией и push-уведомлением
- Dynamic Island: вес + таймер при выполнении, обратный отсчет при отдыхе
- Lock Screen Live Activity
- Оценка упражнения (Heavy/OK/Easy) между упражнениями
- Perceived effort (1-3) при завершении тренировки

#### Кардио (cycling)
- Тип сегментов: warmup, work, recovery, cooldown, steady, interval_block
- Interval_block с `repeats` и `children` -- компактное описание интервалов 3x3, 4x3, 4x4 и т. п.
- Целевая зона: `hr_bpm_range` (абсолютные BPM), `rpe`, или `free`
- Развёрнутая последовательность шагов выполняется по таймеру
- Per-segment-логирование: фактическая длительность, средний/макс HR, время в зоне
- Apple Watch HR-стриминг (когда часы спарены и доступны):
  - iPhone стартует mirroring через WatchConnectivity (`activity: cycling`)
  - Watch запускает `HKWorkoutSession(.cycling)` + `HKLiveWorkoutBuilder`
  - Каждая HR-выборка форвардится на iPhone (`event: hr_sample, bpm: ...`)
  - iPhone-executor показывает большую цифру пульса с цветом по зоне (green=в зоне, red=вне)
  - Без часов: таймер-only, лог пишется без HR-полей
- Прогрессия в схеме: поле `progression { axis, step, advance_when }` -- сейчас отображается как текстовая подсказка пользователю; авто-генерация следующей версии плана -- задел на будущее

#### Apple Watch (общее)
- Mirroring `HKWorkoutSession` для обоих типов тренировок
- Strength: `traditionalStrengthTraining` (без HR-стрима)
- Cycling: `.cycling` (с HR-стримом)
- Требуется HealthKit-авторизация (workouts + heart_rate + active_energy)

#### История и экспорт
- Хронологический список тренировок с planName и templateName
- Детальный просмотр тренировки
- Swipe-to-delete (с удалением на сервере)
- ShareLink экспорт в JSON

#### Сервер
- FastAPI + MongoDB + Docker
- Production API: `https://ironlog.egorianin.ru`; Swagger: `https://ironlog.egorianin.ru/docs`
- TLS terminates in the shared host Caddy, which proxies to the FastAPI container on `127.0.0.1:8844`; there is no public direct-HTTP port. Hosting and deploy: [`DEPLOY.md`](DEPLOY.md).
- JWT auth (регистрация, вход, sliding 90-day expiry)
- Plan sync: `GET /plans` возвращает FULL контент (последняя версия каждого plan_id), polymorphic по plan_type
- Plan upload: `PUT /plan` -- сервер peek'ает `plan_type` и роутит на base + соответствующий per-type валидатор (strength_v1 / cycling_v1). Soft-warnings (например отсутствие `catalog_id`) возвращаются в `_warnings: []` без 422.
- Log sync: fire-and-forget upload + delete; envelope полиморфный. На стороне сервера strength-логи денормализуются: каждая запись упражнения получает `body_part` из catalog (если есть `catalog_id`) или из плана.
- Если auto-upload лога не удался, завершенная тренировка остается `syncedAt == nil` и ретраится при запуске, возвращении приложения в foreground, после login/register и вручную из History.
- Crash reports: `POST /crash`, `GET /crashes` (список своих)
- Настройки: server URL, аккаунт, test connection

#### Exercise Catalog (cross-plan analytics foundation)
- Две Mongo-коллекции: `exercises` (31 seed-запись) + `muscle_groups` (20 seed-записей), нормализованные через `primary_muscles[]`/`secondary_muscles[]`/`antagonist_slugs[]`.
- Сидится на старте контейнера из `tools/seed_data/{exercises,muscle_groups}.json` (idempotent upsert по slug; ручные правки через API сохраняются между рестартами).
- **Slug** -- immutable language-neutral ID. Английский snake_case -- convention для читаемости, но slug это primary key. Никогда не переименовывается; для смысловой замены -- `deprecated: true` + опциональный `replaced_by`.
- **`name`** -- английская строка для display/AI. **`aliases[]`** -- английские синонимы для распознавания моделями (русские фразы пользователя модель сама переводит на английский перед матчем).
- **Convention `(plan_id, exercise_id)`** -- стабильно между версиями одного плана. **`catalog_id` (slug)** -- стабильно между разными планами; нужен чтобы аналитика трекала одно упражнение через смены плана.
- **Read endpoints (public):** `GET /exercises/catalog`, `GET /exercises/{slug}`, `GET /muscle-groups`, `GET /muscle-groups/{slug}`. Catalog response embeds resolved muscle objects.
- **Write endpoints (JWT):** POST/PUT/PATCH-deprecate для exercises и muscle_groups. Требование к следующей миграции: JWT/user record должен нести роль (`admin`, `editor`, `viewer`), write-доступ только `admin`/`editor`, иначе `403`.
- **Field на plan exercise:** опциональный `catalog_id` -- ссылка на slug. Если отсутствует или указывает на несуществующий slug -- сервер возвращает warning, но принимает план. После того как все актуальные планы получат slug-и, переключим warning -> 422.
- iOS сохраняет `catalog_id` в `SDExercise`, переносит его в `SDExerciseLog` и отправляет в strength workout log вместе с денормализованным `body_part`.
- **Backfill** для исторических логов: `tools/backfill_log_body_parts.py` (one-shot, идемпотентный).

#### Strength Analytics (server-side, MVP)
- Три эндпойнта: `/analytics/strength/{exercise-progress, body-parts, overview}` -- все JWT.
- **Метрики:** `volume = Σ(weight × reps)` по working подходам (главная) + `est_1rm` по Эпли (`weight × (1 + reps/30)`).
- **Headline numbers -- relative deltas (%)**: 30-day и 90-day окна, сравнение с предыдущим окном такой же длины. `null` когда нет prior данных (избегаем misleading inf%).
- **Cross-plan continuity** через group key: `catalog_id` если есть, иначе fallback `(plan_id/exercise_id)`. Когда все планы перейдут на catalog_id -- fallback отомрёт.
- Для body_part аналитики используется денормализованное поле `body_part` в логах (см. middleware на POST /log).
- **Не реализовано:** stalled/overreach insights, авто-предложение progression. Раскрываем "только графики" сейчас, insights -- отдельным заходом.
- Cycling-аналитика отложена до накопления нескольких недель cycling-логов.

#### Тесты
- iOS XCTest:
  - `MultipleSupersetPairsTests` -- интеграционный прогон ActiveWorkoutViewModel через v12-layout (две независимые superset-пары в одной группе)
  - `CyclingExpanderTests` -- expand interval_block, path stability, totalDuration
  - `ParsedPlanDispatchTests` -- parse strength/cycling/unknown, import roundtrip
  - `CrashReporterTests` -- идемпотентность install, безопасный no-op uploadPending
- Server pytest (103 tests across 8 suites):
  - `test_base_validator.py` -- shared base contract
  - `test_strength_validator.py` -- strength_v1 (body_part, technique, sets, fractional weight_kg)
  - `test_cycling_validator.py` -- cycling_v1 (kinds, target types, repeats/children, max-depth=1, progression)
  - `test_catalog_seed.py` -- структурные проверки seed-файлов (slug uniqueness, English-only ASCII, muscle resolution, snake_case)
  - `test_strength_warnings.py` -- collect_warnings для отсутствующего/неизвестного catalog_id
  - `test_catalog_validation.py` -- pure-Python validators для POST/PUT payloads
  - `test_analytics_helpers.py` -- Epley 1RM, relative_delta_pct (None edge cases), workout_metrics, split_window, week_start, parse_iso
  - `test_routes.py` -- FastAPI route contracts for `/plans`, `/log`, and strength analytics with an in-memory fake DB

### Вне текущего scope
- PR-трекинг, графики прогресса
- Авто-генерация следующей версии плана из progression-хинтов
- Редактор плана в UI
- Русская локализация UI
- Авто-периодизация (переключение rep-схемы по неделям)
- Watts/cadence таргеты для cycling

## 3. Функциональные требования

### 3.1. Импорт плана
- FR-IMP-01: Импорт JSON через буфер обмена или файл
- FR-IMP-02: Валидация JSON с понятными ошибками
- FR-IMP-03: Превью плана перед подтверждением импорта (своё для каждого типа)
- FR-IMP-04: Поддержка нескольких импортированных планов одновременно (разные типы)
- FR-IMP-05: Повторный импорт с тем же plan_id обновляет существующий
- FR-IMP-06: Bundled sample-plan.json для первого запуска
- FR-IMP-07: Если план не декодируется при server sync -- skip silently (всплывет после обновления приложения); при ручном импорте -- сообщение "формат не поддерживается / обнови приложение"
- FR-IMP-08: Структурная валидация при импорте: plan_type, body_part / segment.kind, technique / target.type, наличие templates
- FR-IMP-09: Auto-dispatch по `plan_type` peek-у: одна точка входа `PlanImportService.parse` возвращает `ParsedPlan` enum

### 3.2. Синхронизация
- FR-SYN-01: Регистрация и вход по email + пароль
- FR-SYN-02: JWT хранится в Keychain, auto-refresh при активности (< 30 дней до expiry)
- FR-SYN-03: При запуске: GET /plans -> сравнение plan_version per type+id -> импорт более новых
- FR-SYN-04: Pull-to-refresh в списке планов
- FR-SYN-05: Fire-and-forget upload лога после завершения тренировки (strength или cycling)
- FR-SYN-06: Fire-and-forget delete лога при swipe-to-delete
- FR-SYN-07: Настройки: server URL, аккаунт (логин/регистрация/выход), test connection
- FR-SYN-08: 401 -> очистка токена, показ "Not logged in"
- FR-SYN-09: Краш-репорты на диск -> upload на следующем старте

### 3.3. Силовая тренировка
- FR-WRK-01: Выбор шаблона -> одно упражнение на экране
- FR-WRK-02: Ввод веса (кнопки -5/-1/+1/+5), повторов. Вес предзаполняется: prescribed -> last workout -> manual
- FR-WRK-03: Таймер отдыха по упражнению. Вибрация + push + Dynamic Island
- FR-WRK-04: Суперсеты: чередование A1/A2, таймер после пары; несколько пар в одной группе обрабатываются последовательно
- FR-WRK-05: Drop-сеты: рабочий + drop с авто-расчетом веса (% снижение)
- FR-WRK-06: Myo-reps: активация + мини-сеты с лимитом, кнопка "Finish exercise"
- FR-WRK-07: Rest-pause: основной сет + продолжения с коротким отдыхом
- FR-WRK-08: Warmup-сеты с отдельным prescribed весом
- FR-WRK-09: SetRoadmap: визуальный список сетов
- FR-WRK-10: Оценка упражнения (Heavy/OK/Easy) между упражнениями
- FR-WRK-11: Perceived effort (1-3) при завершении
- FR-WRK-12: Заметки к упражнению из плана
- FR-WRK-13: Resume незавершенной тренировки

### 3.4. Кардио тренировка
- FR-CYC-01: Выбор cycling-плана и недели/протокола (шаблона) из меню
- FR-CYC-02: Развёртка interval_block в плоскую последовательность шагов на старте
- FR-CYC-03: Большой таймер обратного отсчёта на каждом сегменте; автопереход при истечении
- FR-CYC-04: Цветной бейдж типа сегмента (warmup/work/recovery/cooldown/steady) с иконкой
- FR-CYC-05: Карточка цели: целевой диапазон BPM, заметка к сегменту
- FR-CYC-06: Skip / Pause / Finish -- ручное управление
- FR-CYC-07: Apple Watch HR live (если доступны): большая цифра пульса с цветом (green=в зоне, red=вне)
- FR-CYC-08: Если часов нет: "No heart-rate source", таймер крутится, лог без HR
- FR-CYC-09: Per-segment лог: фактическая длительность, avg/max HR, time-in-zone, флаг skipped
- FR-CYC-10: Финальная форма: notes + perceived effort -> Save
- FR-CYC-11: Поддержка типов цели: hr_bpm_range, rpe, free

### 3.5. Dynamic Island + Live Activity
- FR-DI-01: Performing: иконка гантели + вес (зеленый)
- FR-DI-02: Resting: иконка таймера + обратный отсчет (синий)
- FR-DI-03: Overtime: "GO!" (желтый)
- FR-DI-04: Expanded: название упражнения, вес/следующий сет, прогресс-бар
- FR-DI-05: Lock Screen: название + вес/следующий сет + таймер

### 3.6. История и экспорт
- FR-HIS-01: Хронологический список тренировок с planName и templateName
- FR-HIS-02: Детальный просмотр тренировки
- FR-HIS-03: Swipe-to-delete (с удалением на сервере)
- FR-HIS-04: ShareLink экспорт в JSON

### 3.7. Сервер
- FR-SRV-01: POST /register, POST /login -> JWT
- FR-SRV-02: GET /plans -- список FULL планов (последняя версия каждого plan_id, опциональный type-фильтр)
- FR-SRV-03: PUT /plan -- загрузка с полной цепочкой валидации (base -> per-type)
- FR-SRV-04: POST /log -- upsert логов по workout ID (polymorphic envelope)
- FR-SRV-05: GET /log -- запрос логов (since, template_id, type, limit)
- FR-SRV-06: DELETE /log/{id} -- удаление лога
- FR-SRV-07: GET /schema -- описание схемы (public, per-type)
- FR-SRV-08: POST /crash -- приём крашрепорта пользователя
- FR-SRV-09: GET /crashes -- список своих крашей
- FR-SRV-10: Валидация plan_type, 422 для неизвестных типов
- FR-SRV-11: GET /exercises/catalog -- список упражнений с резолвом мышц (фильтр по plan_type)
- FR-SRV-12: POST /exercises/catalog -- добавление нового упражнения (JWT)
- FR-SRV-13: PUT /exercises/{slug} -- редактирование (slug immutable, JWT)
- FR-SRV-14: PATCH /exercises/{slug}/deprecate -- soft-delete с опциональным replaced_by
- FR-SRV-15: GET /muscle-groups -- мышечные группы (фильтр по region)
- FR-SRV-16: PUT /plan -- soft warnings в `_warnings: []` для отсутствующего catalog_id
- FR-SRV-17: POST /log -- денормализация body_part в strength логах при записи
- FR-SRV-18: GET /analytics/strength/exercise-progress -- per-exercise volume + est_1rm series + 30/90-day relative deltas
- FR-SRV-19: GET /analytics/strength/body-parts -- weekly volume + 30/90-day deltas per body_part
- FR-SRV-20: GET /analytics/strength/overview -- top progressing exercises (volume_pct_30d), body_part summary, total workouts count
- FR-SRV-21: GET /exercises/{slug}/docs -- localized exercise execution documentation (public)
- FR-SRV-22: PUT /exercises/{slug}/docs -- upsert localized exercise documentation (JWT, server-managed content_version)
- FR-SRV-23: GET /exercise-docs/missing -- catalog exercises without docs for a locale/status

## 4. Нефункциональные требования
- NFR-01: Offline-first: полная функциональность без интернета, sync при наличии
- NFR-02: Нативный iOS (Swift/SwiftUI), iOS 17+, SwiftData
- NFR-03: Минимальный UI, большие тап-зоны, минимум навигации
- NFR-04: Данные хранятся локально (SwiftData), копия на сервере (MongoDB)
- NFR-05: JSON-экспорт до 1MB на 6 месяцев
- NFR-06: Время запуска < 1 секунда
- NFR-07: Dark mode поддерживается автоматически (system theme)
- NFR-08: Фоновая устойчивость: Date-based таймеры работают корректно после background/foreground
- NFR-09: JWT sliding expiry (90 дней), auto-refresh при активности
- NFR-10: Sync-ошибки не блокируют UI (fire-and-forget)
- NFR-11: Краш-репорт пишется атомарно в Application Support, безопасен к повторным сбоям
- NFR-12: Security -- HTTPS/TLS for production API, no placeholder JWT secrets, validation on all JSON inputs, rate limiting/account lockout before public multi-user release
- NFR-13: Privacy -- PII in logs is masked/redacted, crash/workout retention policy is documented, user consent required for HealthKit and sync
- NFR-14: Observability -- structured server logs, health checks, basic metrics/alerts for auth, sync, crash ingest, and Mongo failures
- NFR-15: Data Protection -- Mongo backups with documented retention, restore drill, RTO/RPO targets, and encryption-at-rest on production storage
- NFR-16: API/schema versioning -- breaking changes require schema timestamp bump, compatibility window, and explicit client upgrade behavior

## 5. Ключевое ограничение
- Никакого ручного создания планов в UI -- только импорт JSON или sync с сервера
- Приложение = исполнитель плана + логгер
- Анализ прогресса и корректировка плана -- на стороне AI через сервер

## 6. Schema & Compatibility
- Каждый план несет поле `schema` -- timestamp идентификатор схемы
- Серверная JSON-схема содержит `x-schema-id` с тем же timestamp
- Приложение хранит `PlanSchema.id(for: type)` для каждого поддерживаемого типа
- **Валидация структурная**: plan_type, segment kinds (cycling) / body_part+technique (strength), наличие обязательных полей
- Загруженные планы не проходящие валидацию -> "not supported"
- Ответ сервера не декодируется при sync -> skip silently; при ручном импорте -> user-facing unsupported-format error
- PlanType -- enum на обеих сторонах: `strength`, `cycling`

### Schema Evolution & Negotiation

- Additive compatible changes may keep the existing schema timestamp when old
  clients safely ignore the new field. Required fields, enum changes, removed
  fields, or semantic changes require a new schema timestamp.
- iOS exposes supported schema IDs through `PlanSchema.id(for:)` for each
  `PlanType` (`strength`, `cycling`). A future `/plans` negotiation should send
  them in `X-Supported-Schemas`.
- Server behavior after negotiation lands: return compatible plans, or `426
  Upgrade Required` with `min_schema_ids` when no compatible version exists.
- Compatibility window: server supports current + previous schema for at least
  90 days after a breaking schema release.

## 7. JSON-схемы
- `schemas/strength-plan.import.schema.json` -- strength import v1 (templates -> groups -> exercises -> sets, optional `catalog_id`), `x-schema-id: 2026-04-30T00:00:00Z`
- `schemas/cycling-plan.import.schema.json` -- cycling import v1 (templates -> segments, interval_block, target types), `x-schema-id: 2026-04-27T00:00:00Z`
- `schemas/strength-workout-log.export.schema.json` -- схема экспорта strength-логов
- `schemas/cycling-workout-log.export.schema.json` -- схема экспорта cycling-логов
- `schemas/sample-plan.json` -- рабочий strength-пример

## 8. Catalog seed
- `ironlog-server/tools/seed_data/exercises.json` -- 31 упражнение в стартовом наборе. Все английские names + aliases. Slug-convention: `<movement>_<equipment>_<modifier?>`.
- `ironlog-server/tools/seed_data/muscle_groups.json` -- 20 мышечных групп с антагонистами и регионом.
- `ironlog-server/tools/seed_data/exercise_docs.ru.json` -- стартовые draft-карточки техники на русском для всех текущих упражнений.
- Сидинг идемпотентный (`tools/bootstrap_catalog.py`); ручные правки через API сохраняются.

## 9. Exercise documentation reference
- Mongo-коллекция `exercise_docs`, отдельная от `exercises`: ключ `(exercise_slug, locale)`.
- Public reads: `GET /exercise-docs`, `GET /exercise-docs/missing`, `GET /exercises/{slug}/docs`.
- JWT write: `PUT /exercises/{slug}/docs?locale=ru`.
- Сервер сам увеличивает `content_version` при каждом PUT.
- `sources[]` обязателен; контент пишется оригинальным текстом, без копирования чужих инструкций.
- `media[]` хранит только URL/метаданные; картинки должны быть owned/generated/licensed/reusable.
- Статусы: `draft`, `reviewed`, `deprecated`. App-ready контент должен использовать `reviewed`.
