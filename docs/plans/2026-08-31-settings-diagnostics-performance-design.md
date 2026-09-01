# NotchApp settings, diagnostics, and idle performance

Status: implemented and verified on 2026-08-31

## Goal

Снизить фоновую нагрузку компактного NotchApp, добавить отдельный экран настроек и диагностики музыки, сделать Calendar/Now Playing подменяемыми в тестах, сохранить пользовательские параметры и исправить вывод ошибки Codex app-server.

## Success criteria

- После 30 секунд простоя компактный NotchApp использует около `<2% CPU` на текущем Mac вместо измеренных `~9.4%`; замер выполняется тем же `ps`/`sample` способом до и после изменения.
- Основная навигация по-прежнему содержит только `Лимиты`, `Календарь` и `Музыка`.
- Шестерёнка открывает отдельный экран настроек, а возврат восстанавливает ранее выбранную панель.
- Hover-задержка настраивается от `0` до `1` секунды с шагом `0.1`; значение и последняя основная панель переживают перезапуск.
- Диагностика музыки показывает источник, приложение, разрешение и время последнего успешного обновления.
- Calendar и Now Playing можно заменить fake-реализациями в unit-тестах.
- Ошибка Codex app-server содержит реальный `localizedDescription`.

## UX

В заголовке expanded-панели появляется кнопка-шестерёнка. Она не становится четвёртой основной вкладкой и не меняет сохранённый `PanelID`.

```text
+------------------------------------------+
| NotchApp                             [*] |
| [Лимиты] [Календарь] [Музыка]            |
|                                          |
|              текущая панель              |
+------------------------------------------+

+------------------------------------------+
| <- Настройки                             |
| Наведение       [0.0 -- 0.5 -- 1.0 сек] |
| Последняя вкладка              включено  |
|                                          |
| Музыка                                   |
| Источник        Accessibility            |
| Приложение      Yandex Music              |
| Доступ          разрешён                 |
| Обновлено       12 сек назад             |
| [Открыть настройки] [Обновить]           |
+------------------------------------------+
```

Настройки используют существующие цвета, радиусы и типографику и прокручиваются внутри текущего expanded-размера. При возврате из System Settings состояние Accessibility перепроверяется автоматически. Deep link открывает раздел Accessibility/Device Control where possible; при недоступном anchor открывается Privacy & Security и остаётся существующая текстовая инструкция.

## State and persistence

Небольшой `AppPreferences` boundary скрывает `UserDefaults` и хранит:

- `hoverExpansionDelay`, default `0.5`, допустимый диапазон `0...1`;
- `lastSelectedPanel`, только один из трёх основных `PanelID`.

`NotchViewModel` получает preferences через initializer, читает значения при создании и сохраняет их только при изменении. Экран настроек — отдельное transient-состояние (`isShowingSettings`) и никогда не записывается как последняя панель.

## Provider boundaries

Вводятся узкие `CalendarProviding` и `NowPlayingProviding` protocols, соответствующие только операциям, которые реально использует `NotchViewModel`. Текущие concrete providers остаются default-реализациями production initializer. Тесты передают fakes без EventKit, MediaRemote или Accessibility.

`NowPlayingProviding` дополнительно публикует `NowPlayingDiagnostics`:

- source: `none`, `mediaRemote` или `accessibility`;
- application name, если оно известно;
- Accessibility access state;
- timestamp последнего успешного snapshot.

Диагностика не меняет стратегию выбора источника: сначала MediaRemote, затем универсальный Accessibility fallback.

## Performance behavior

1. `CompactQuotaBorder` сохраняет прогресс и цвета, но перестаёт использовать постоянно работающий `TimelineView(.animation(minimumInterval: 0.06))`. Пульсация заменяется статическим warning-состоянием.
2. Ollama `WKWebView` присоединяется к окну только для загрузки/авторизации и отсоединяется после чтения страницы. Persistent website data/cookies сохраняются; новый WebView на каждый poll не создаётся.
3. Now Playing использует интервал `1 s` только когда expanded-панель открыта на `Музыке`; в остальных состояниях — `5 s`. MediaRemote notifications по-прежнему инициируют немедленный refresh.
4. Одинаковый semantic snapshot не вызывает повторный `onChange` и SwiftUI redraw. Локальный progress UI продолжает обновлять таймкод без полного provider refresh.

## Artwork fallback

Accessibility fallback best-effort ищет artwork в уже найденном player/metadata subtree. Поддерживаются image value/data и HTTPS image URL, загружаемый вне main actor с timeout `3 s` и лимитом `5 MB`. Ошибка, неподдерживаемое значение или отсутствие изображения не ломают snapshot: остаётся текущий waveform placeholder. Player-specific API и scraping страницы не добавляются.

## Error handling

- Permission denial отображается в диагностике и существующем empty state, без автоматического запроса системного доступа.
- Settings deep-link failure не считается fatal и оставляет ручную инструкцию.
- Ошибка artwork не заменяет корректные title/artist/controls.
- Provider failure сохраняет существующие error/empty states.
- Codex app-server message использует Swift interpolation: `\(error.localizedDescription)`.

## Test strategy

Каждое изменение начинается с failing behavioral test.

- Preferences: default, range clamping, save/restore последней основной панели.
- Hover policy: выбранная задержка действительно определяет открытие; существующие collapse regressions остаются зелёными.
- Provider injection: fake Calendar/Now Playing управляют loading, permission, snapshot и diagnostics state `NotchViewModel`.
- Polling policy: `1 s` только для видимой Music, `5 s` иначе.
- Semantic publication: равный snapshot не публикуется повторно; изменение track/playback публикуется.
- Diagnostics: source/app/access/update timestamp проходят от provider до settings model.
- Codex error formatting содержит тестовую ошибку, а не literal placeholder.
- Existing signing and notch geometry/hover tests остаются зелёными.

Live verification:

- открыть/закрыть settings, изменить hover delay;
- выбрать `Музыка`, перезапустить и подтвердить восстановление вкладки;
- проверить MediaRemote/Accessibility diagnostics и переход в System Settings;
- проверить музыку и controls после adaptive polling;
- выполнить signing check и пересобрать `Build/NotchApp.app`;
- повторить compact idle CPU sample после 30 секунд.

## Non-goals

- Не исправлять в этом пакете пересчёт размера при переключении мониторов.
- Не добавлять четвёртую основную вкладку или plugin architecture.
- Не добавлять новый player-specific API, авторизацию Яндекс Музыки или внешние зависимости.
- Не менять существующую физическую notch safe zone, три основные панели или codesign scheme.

## Stop condition

Остановиться после прохождения unit/signing tests, live settings/music/persistence scenarios и измеренного снижения compact idle CPU. Не расширять работу на новые панели, monitor migration или отдельную redesign-задачу.
