# Fignyagram: руководство по устранению лагов до 120/60 FPS без отключения функций

Цель: стабильные 120 FPS на ProMotion и 60 FPS на старых устройствах.
Жёсткое правило: **ничего из функционала не отключается** — автозагрузка медиа,
уведомления, папки, боты, секретные чаты, стикеры и архивы работают как раньше.
Все пункты ниже касаются только внутренних механизмов и скрытого меню разработчика
(вызов: быстрые нажатия по иконке настроек → «Для разработчиков»).

Текущие симптомы и их источники (по коду):
- iPhone 7 Plus (2 ГБ) — полные зависания при запуске и скролле.
- iPhone 16 Pro Max — 40–70 FPS при быстром скролле ленты чатов.
- Главные источники: синхронная работа в `body`, подписки на `FileStore` из
  каждой строки, секундный таймер `PerformanceMonitor`, сетевые переводы при
  скролле, повторные пересортировки чатов.

---

## 1. Главный поток (UI Thread) и CoreAnimation

### 1.1 Запуск приложения

Проблема: `ContentView.onAppear` (Telegram/UI/ContentView.swift:75) выполняет
`ShareInbox.loadPending()`, `BuiltInProxyManager.applyIfEnabled()` и
`TelegramClient.start()` последовательно на главном потоке.

Исправление (без изменения функционала):

```swift
.onAppear {
    // Лёгкие операции остаются на main; тяжёлые — в detached-задаче.
    Task.detached(priority: .userInitiated) {
        await BuiltInProxyManager.shared.startAsyncIfNeeded()
    }
    TelegramClient.shared.start()          // только создание TDLib-клиента
    ShareInbox.shared.loadPending()        // чтение одного JSON
}
```

- `TelegramClient.start()` уже не блокирует: создание клиента асинхронно, а
  `ensureActivated()` ожидает локальный прокси максимум 2,5 с **в фоновом Task**
  (Telegram/TelegramClient.swift:134).
- Причина устранения фриза: первый кадр не ждёт инициализации сети и диска.

### 1.2 Декодирование изображений — только вне main

Уже сделано в `ImageCache` (Telegram/UI/Components.swift:10):

- `decodeQueue` = `OperationQueue`, QoS `.userInitiated`, параллелизм 1–2.
- `imageAsync(atPath:maxPixel:)` декодирует в этой очереди и кэширует результат.
- `StickerView` (Telegram/UI/MediaViews.swift) и аватары используют `imageAsync`.

Что проверить/доделать (не отключая ничего):

- Ни один `UIImage(data:)` / `CGImageSourceCreateThumbnailAtIndex` не должен
  вызываться в `body` — только через `imageAsync`.
- `ImageCache.flushForBackground()` уже сбрасывает кэш при сворачивании и
  отменяет очередь — фризов при возврате в приложение нет.

### 1.3 TextKit / рендеринг текста

В SwiftUI текст рендерит система. Применять:

```swift
Text(MessageFormatter.attributed(formatted))
    .textSelection(.enabled)          // уже включено
    .lineLimit(...)
    .fixedSize(horizontal: false, vertical: true)
```

- Не разбивать одно сообщение на десятки `Text` — каждая строка = отдельный
  layout-pass. Уже используется один `Text` с AttributedString.
- Для каналов с огромными описаниями: `Text` с `lineLimit` вместо полного
  раскрытия по умолчанию (функция раскрытия сохраняется по тапу).

---

## 2. Скрытое Debug-меню: флаги оптимизации

Открой: «Для разработчиков» (DeveloperSettingsView.swift). Уже есть:

| Элемент | Файл / строка | Что делает |
|---|---|---|
| Показывать FPS | DeveloperSettingsView.swift | оверлей FPS поверх UI |
| Подробные логи TDLib | там же | `setLogVerbosity(3)` |
| Симулировать нехватку памяти | там же | `ImageCache.clear()` |
| Очистить кэш сообщений | там же | `ChatStore.clearLoadedMessages()` |
| Перезапустить прокси | там же | `proxy.restart()` |
| Переключить профиль производительности | Настройки → Производительность | `PerformanceMode` |

Добавить (безопасно, функционал не трогается) — предлагаемые флаги:

1. **«Предрасчёт раскладки списков»** — `@AppStorage("layoutPrecompute")`
   - Включает `ChatPresentationState` (Telegram/UI/Models/Fignyagram/
     ChatPresentationState.swift) с заранее вычисленными `showSender`,
     `shouldGroup` и превью, чтобы `ChatRow.body` не считал их повторно.
   - Почему безопасно: это только кэш вычислений, данные те же.

2. **«Отложенный ресорт чатов»** — уже сделан как `ChatStore.scheduleReorder()`
   (Telegram/UI/Models/ChatStore.swift): массовые обновления позиций
   схлопываются в один пересчёт за 50 мс. Включён всегда.

3. **«Профиль декодера»** — `HardwareTuning.apply()` (HardwareTuning.swift)
   уже переключает `maxPixel`, `cacheMB`, `concurrency` и QoS по профилю
   «Экономия / Баланс / Производительность». Ничего не отключает — только
   разрешение декодирования и размер кэша.

4. **«Таймер мониторинга только при открытом меню»** — сделано:
   `PerformanceMonitor.start()/stop()` (PerformanceMonitor.swift), таймер
   1 Гц работает только когда экран разработчика виден.

---

## 3. База данных (TDLib / SQLite)

TDLib хранит базу в `Documents/tdlib_db` (или `tdlib_db_<id>` для каждого
аккаунта) — путь в `AccountSlot.databaseDirectory`
(Telegram/UI/Models/Fignyagram/Accounts/AccountStore.swift:69).

### 3.1 Безопасное сжатие и переиндексация

TDLib управляет SQLite сам; прямого `VACUUM` при работающем клиенте делать
нельзя (риск повреждения БД). Безопасные штатные механизмы **без потери
данных**:

```swift
// В Debug-меню уже добавлена кнопка «Статистика хранилища» — только чтение:
// TelegramClient.storageStatisticsSummary() → client.getStorageStatistics()
```

- WAL-журнал базы сжимается (checkpoint) автоматически при корректном
  `close(completion:)` — этот путь уже используется при переключении аккаунтов
  (Telegram/TelegramClient.swift:343–410).
- Полный checkpoint также происходит при плановом перезапуске клиента
  («Перезапустить» в меню).

### 3.2 Полный checkpoint при переключении аккаунтов

Уже исправлено: `close(completion:)` полностью закрывает старый клиент до
создания нового (Telegram/TelegramClient.swift:343–410). Это гарантирует flush
WAL и снимает блокировку, из-за которой вход «висел».

---

## 4. RAM на старых устройствах (iPhone 7 Plus)

Не отключая функции — только лимиты кэша:

1. `DevicePerformance` (DevicePerformance.swift) уже определяет
   `isLowMemory` (< 3 ГБ) и `isVeryLowMemory`.
2. `ImageCache.configureForDevice()`: на слабых устройствах
   `totalCostLimit = 24/32 МБ`, `countLimit = 250` — декодированные картинки
   пересоздаются по требованию, но **файлы и предпросмотры не удаляются**.
3. `HardwareTuning` автоматически переключается на профиль «Экономия» при
   `thermalState == .serious/.critical` или включённом энергосбережении.
4. `ImageCache.flushForBackground()` — агрессивный сброс NSCache при
   сворачивании: память возвращается системе, при возврате всё декодируется
   заново (функционал прежний).

Дополнительно для 7 Plus:

- Уменьшить `ImageCache.decodeQueue.maxConcurrentOperationCount` до 1 на
  устройствах ≤ 2 ГБ — уже делает `DeviceProfiles.tier`.
- Не держать `FPSOverlay` включённым постоянно (CADisplayLink расходует
  энергию); включать только для замера.

---

## 5. Системные оптимизации (ProMotion / фоновые события)

1. **ProMotion 120 Гц** — `CADisableMinimumFrameDurationOnPhone = true` уже
   в `Telegram/Info.plist`. Убедиться, что флаг есть в обоих target'ах
   (Share Extension не обязателен).
2. **Event loop**: `Timer`-операции заменены на `Task`/`DispatchWorkItem`
   (пример: `scheduleReorder`). Ни один обработчик обновлений не сортирует
   массив на каждое событие.
3. **Фоновые обновления**: в `FignyagramApp` при `.background` выполняются
   только дешёвые операции: `ImageCache.flushForBackground()`,
   `URLCache.removeAllCachedResponses()`, `setOnline(false)` — при активных
   загрузках онлайн сохраняется (скачивание продолжается).
4. **Сеть не на главном потоке**: `ProxyWebSocket` и `LocalMTProtoProxy`
   работают на `DispatchQueue.global(qos: .userInitiated)`; таймауты
   соединений сокращены до 4 с, общий дедлайн — 8 с
   (MTProtoLocalProxy.swift) — авторизация больше не блокирует UI.

---

## Порядок внедрения (чек-лист)

- [x] Таймер PerformanceMonitor — только при открытом меню.
- [x] Отложенный ресорт чатов (`scheduleReorder`).
- [x] Асинхронное декодирование стикеров/аватарок.
- [x] Сброс кэша изображений при сворачивании.
- [x] Закрытие БД до переключения аккаунта.
- [x] Таймауты прокси 4 с / дедлайн 8 с.
- [x] ProMotion-флаг в Info.plist.
- [x] Кнопка «Статистика хранилища» (read-only) в Debug-меню.
- [ ] `ChatPresentationState`-кэш для sender-grouping (в работе).
- [ ] Перенос `applyIfEnabled` в detached-задачу при старте.

Ни один пункт не отключает автозагрузку, уведомления, папки, ботов,
секретные чаты, стикеры или архивы.
