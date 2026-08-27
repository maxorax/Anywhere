# Отличия от исходного приложения

Что изменено относительно апстрима (NodePass «Anywhere»). Служит и историей работ,
и картой для того, чтобы отделить свои доработки от оригинала.

Состояние на 27 августа 2026.

---

## 1. Переименование в MTurn

`Turn.xcodeproj/project.pbxproj` — `INFOPLIST_KEY_CFBundleDisplayName` в 10 конфигурациях
(iOS, watchOS, tvOS, Network Extension, Widget).

Bundle ID, app group, keychain, URL-схемы, UTI, имена таргетов и папок **не трогали** —
`com.maxorax.turn` везде как было. Причина переименования: имя «Turn» занято в App Store
другим аккаунтом, запись `com.maxorax.turn` создана вручную под именем MTurn.

Не тронуты, хотя содержат слово Turn: User-Agent `Turn/версия` (панель подписки матчит
по нему правила) и глобальный JS-объект `Turn` в движке MITM-скриптов (переименование
сломало бы пользовательские скрипты).

## 2. Версия в одном месте

Новый `Config/Version.xcconfig`:

```
APP_VERSION = 1.0.0
APP_BUILD_NUMBER = 1
```

Подключён как `baseConfigurationReference` к Debug и Release уровня проекта. Все 12
конфигураций таргетов ссылаются на `$(APP_VERSION)` / `$(APP_BUILD_NUMBER)`; литеральных
версий в `project.pbxproj` не осталось.

Тонкость: `$(...)` в pbxproj обязан быть в кавычках, иначе файл перестаёт быть валидным plist.

## 3. Экран «О приложении»

- Новый `Turn/Views/Settings/AboutView.swift` — имя, версия из Info.plist, текст про учебные цели.
- `SettingsItem` — добавлен case `about`.
- `SettingsView.aboutSection` — вместо ссылки на Telegram-группу и «Acknowledgements» одна строка About.
- **Удалён** `Turn/Views/Settings/AcknowledgementsView.swift`.

⚠️ Вместе с ним ушли уведомления об открытых лицензиях: lwIP (BSD), libyaml (MIT),
BLAKE2/BLAKE3 (CC0/Apache), MaxMind GeoLite2 (CC BY-SA 4.0). MIT и BSD требуют
воспроизводить текст лицензии в распространяемом продукте.

## 4. Выгрузка логов

- Новый `Turn/Views/Settings/LogArchive.swift` — рендер логов в текстовый файл с шапкой
  (версия приложения, ОС, модель устройства).
- `LogListView` — кнопка «Поделиться» в тулбаре, отдаёт файл `MTurn-log-<дата>.txt` через ShareLink.
- Новый `Turn Tests/LogArchiveTests.swift` — 3 теста на формат.

## 5. Починка холодного старта TURN

Проблема: на старте `shouldRelay` всегда видел «неопознанную сеть» и гонял 10-секундную
пробу даже на Wi-Fi, а первый апдейт path-монитора рвал все соединения.

- `PathMonitorConcurrencyBridge.firstPath(timeout:)` — одноразовое чтение пути.
- `TunnelStack+Lifecycle.seedNetworkContext(isWiFi:isCellular:ssid:)` — засев до старта стека.
- `PacketTunnelProvider.startTunnel` — засев до первого `prepared`; общий хелпер `networkContext(for:)`.
- `TunnelStack+Lifecycle.switchConfiguration` — guard: не рестартовать стек, если конфиг не изменился.

## 6. Починка зацикливания капчи

Проблема: VK отвергал капчу, ядро гоняло фазы `captcha → error → captcha`, шит мигал;
«Закрыть» возвращал его через 3 секунды, выйти было некуда.

- `TurnCaptchaModel.apply(_:)` — переходные фазы `connecting`/`error` не трогают шит.
- `TurnCaptchaModel.suppressed` — «Закрыть» действительно закрывает.
- `TurnCaptchaModel.present()` — вернуться к капче через тост.
- `TurnCaptchaView` — «Закрыть» теперь отключает соединение (`disconnectVPN()`).

## 7. Тост с этапами подключения

Новый `Turn/Views/Components/ConnectionStageToast.swift` — капсула сверху, собирает этап из
`VPNStatus` и `TurnState`. Подключён overlay-ом в `MainTabView`. Тап по этапу с капчей
открывает её.

## 8. Таймер работы соединения

- `VPNViewModel.connectedSince` — из системного `NEVPNConnection.connectedDate`
  (переживает перезапуск приложения, в отличие от локального счётчика).
- `HomeView.statusLabel` — таймер под статусом.

## 9. Починка залипшего состояния TurnCore

Проблема: тост про капчу вылезал при прямом подключении по Wi-Fi.

- `TurnCore.state` — возвращает `.idle`, если ни `active`, ни `pending` не заданы
  (Go-ядро — долгоживущий синглтон и помнит последнюю фазу после остановки).
- `TurnCore.deactivate()` — срабатывает и когда `turn.isRunning()`, даже если учёт потерян.

## 10. Урезанные настройки

`SettingsView.HeldBack` — флаги, скрывающие пункты до будущих обновлений:

| Флаг | Что скрыто |
|---|---|
| `personalization` | иконки приложения, темы |
| `adBlocking` | тумблер блокировки рекламы |
| `countryBypass` | пикер обхода по стране |
| `security` | Allow Insecure, Trusted Certificates, Trusted Network, **VK TURN** |
| `utilities` | Purify, Reflection, MITM |
| `advancedSettings` | экран дополнительных настроек |

Вся обвязка на месте — включение это `true` в нужной строке.

⚠️ У пользователей, успевших включить блокировку рекламы, в App Group осталось назначение
`ADBlock → REJECT`. Сейчас безвредно (правил нет), но при появлении настоящей `Rules.db`
блокировка включится сама, а тумблера для отключения не будет.

## 11. Локализация

Добавлено 11 ключей с переводами на все 8 языков (ar, en, es, fa, ru, tr, vi, zh-Hans):
`Version %@ (%@)`, `Purpose`, текст про учебные цели, `Export Logs`, `Connecting through VK`,
`Fetching relay credentials.`, `Tap to solve it.`, `VK relay failed`,
`Connecting directly instead.`, `Relay ready`, `Traffic goes through the VK relay.`

Каталог правится с сохранением исходного порядка ключей и форматирования Xcode, так что
в диффе только добавления.

---

## Известное, но не сделанное

Из обзора устойчивости переключения «прямое ↔ VK TURN» остаётся 11 пунктов из 12
(исправлен только первый). Самые тяжёлые:

- решение о релее принимается однократно, по одной пробе, без ретраев и гистерезиса;
- смерть прямого пути **без** смены класса интерфейса не замечается вообще;
- из релея нет пути назад, пока сеть та же;
- `startTunnel` может ждать до ~130 с при системном вотчдоге около 60 с;
- гонки вокруг `prepared`/`TurnCore` (провайдер не актор);
- в режиме `.always` неудачный запуск релея тихо уходит в прямое и больше не пытается.

Отдельно: бандлящаяся `LocalPackages/TurnRules/.../Rules.db` — пустая заглушка
(0 правил). Из-за неё не работают блокировка рекламы, обход по стране и встроенные
сервисные наборы правил. Историческая база на 1.5 МБ есть в git:
`git show cefe495^:Shared/DataStore/Rules.db`.

Тестовый таргет не собирается из-за устаревшего `Turn Tests/TurnLinkTests.swift`
(`TurnSubscription.Parsed` поменял форму) — не наша правка, но блокирует прогон тестов.
