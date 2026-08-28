# IronLog -- AI Gym Tracker

iOS-приложение для трекинга силовых тренировок + sync-сервер. AI генерирует планы, приложение исполняет, логи синхронизируются для анализа.

## Концепция

1. **Импорт плана** -- Claude генерирует JSON-план, загружает на сервер. Приложение синхронизирует автоматически или импортирует вручную
2. **Тренировка** -- приложение ведет по упражнениям: prescribed вес/повторы, таймер отдыха, Dynamic Island, техники (drop-сеты, myo-reps, rest-pause, суперсеты)
3. **Синхронизация логов** -- после тренировки лог автоматически отправляется на сервер. Claude забирает логи для анализа прогресса и корректировки плана

## Стек

### iOS-приложение (`IronLog/`)
- Swift / SwiftUI / SwiftData (iOS 17+)
- MVVM + Services
- ActivityKit (Dynamic Island + Lock Screen Live Activity)
- WidgetKit (виджет-расширение для Live Activity)
- XcodeGen (генерация xcodeproj из project.yml)

### Sync-сервер (`ironlog-server/`)
- Python / FastAPI / MongoDB (motor async)
- JWT auth (sliding 90-day expiry)
- Docker Compose (Caddy TLS proxy + app + mongo)
- Production API: `https://v170184.hosted-by-vdsina.com`
- Swagger: `https://v170184.hosted-by-vdsina.com/docs`

## Возможности

### Синхронизация
- Регистрация / вход по email + пароль
- JWT в Keychain, auto-refresh при активности
- Sync плана: автоматическая проверка новой версии при запуске
- Баннер обновления: "New plan vN available" или "Update app" (если план не декодируется)
- Структурная валидация: приложение проверяет plan_type, body_part, technique, наличие templates/groups/exercises/sets
- Несовместимые планы показываются как "not supported" с timestamps схем для отладки
- Upload логов: fire-and-forget после завершения тренировки
- Delete логов: синхронное удаление на сервере при swipe-to-delete
- Несинхронизированные завершенные тренировки автоматически ретраятся при запуске,
  возврате приложения в foreground и после входа в аккаунт
- Настройки: server URL, аккаунт, test connection

### Импорт плана
- JSON через буфер обмена, файл или sync с сервера
- Превью плана перед подтверждением
- Повторный импорт обновляет существующий план (один план на plan_id)
- Поддержка нескольких планов с выбором (по умолчанию -- последний использованный)
- Shared Base Contract: plan_type, plan_id, plan_version, plan_name, schema (timestamp), created_at

### Тренировка
- Выбор плана: saved -> last used -> first available (авто-выбор если один)
- Пошаговый UI: одно упражнение на экране, свайп для навигации
- Prescribed вес/повторы/RIR из плана с автозаполнением
- Заметки к упражнению из плана (notes)
- Техники: straight, drop_set, myo_reps, rest_pause, superset
- TechniqueFlow -- stateless протокол для управления потоком сетов
- SetRoadmap -- визуальный список сетов (warmup/working/drop/mini)
- WeightStepper -- кнопки -5/-1/+1/+5 kg
- Таймер отдыха с вибрацией и уведомлениями
- Dynamic Island: вес + таймер во время сета, обратный отсчет во время отдыха
- Lock Screen Live Activity
- Оценка упражнения (Heavy/OK/Easy) между упражнениями
- Perceived effort (1-3) при завершении тренировки
- Список упражнений (sheet с прогрессом)
- max_mini_sets для myo-reps (лимит мини-сетов)

### История и экспорт
- Хронологический список тренировок с планом и шаблоном
- Детали тренировки с полным логом
- Swipe-to-delete (с удалением на сервере)
- ShareLink экспорт в JSON
- Оценки упражнений и planName в экспорте

## Сервер

| Method | Path | Auth | Описание |
|--------|------|------|----------|
| GET | /health | нет | Healthcheck |
| GET | /schema | нет | Описание схемы по plan_type |
| GET | /agent-instructions/plan-import | нет | Markdown-инструкция для AI-агентов по генерации импортируемых планов |
| GET | /agent-instructions/plan-import.json | нет | Та же инструкция с live-ссылками в JSON |
| PUT | /agent-instructions/plan-import | JWT + админ | Обновить инструкцию в БД без редеплоя контейнера. Требует, чтобы email был в `ADMIN_EMAILS` или на пользователе стоял `is_admin: true` |
| POST | /register | нет | Регистрация -> JWT |
| POST | /login | нет | Вход -> JWT |
| GET | /plans | JWT | Последняя версия каждого plan_id, FULL content |
| PUT | /plan | JWT | Загрузка новой версии (с валидацией) |
| POST | /log | JWT | Upsert лога тренировки |
| GET | /log | JWT | Запрос логов (since, template_id, type, limit) |
| DELETE | /log/{id} | JWT | Удаление лога |
| POST | /crash | JWT | Приём краш-репорта |
| GET | /crashes | JWT | Последние краш-репорты пользователя |

## JSON-схемы

- `schemas/strength-plan.import.schema.json` -- схема импорта силового плана (документирована для AI)
- `schemas/cycling-plan.import.schema.json` -- схема импорта вело-плана
- `schemas/strength-workout-log.export.schema.json` -- схема экспорта силового лога
- `schemas/cycling-workout-log.export.schema.json` -- схема экспорта вело-лога
- `schemas/sample-plan.json` -- пример плана с Shared Base Contract
- `docs/AI_AGENT_PLAN_IMPORT.md` -- инструкция для AI-агентов по генерации и загрузке планов

## Сборка

```bash
# iOS
cd IronLog && xcodegen generate && open IronLog.xcodeproj

# Server
cd ironlog-server && docker compose up --build -d
```

Production compose exposes HTTPS through Caddy on `443`.
The legacy direct HTTP port `8844` is kept temporarily for old app builds.

## Структура

См. [ARCHITECTURE.md](docs/ARCHITECTURE.md)
