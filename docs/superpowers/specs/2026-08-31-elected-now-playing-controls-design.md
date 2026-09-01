# Elected Now Playing controls and Music layout

Status: approved for implementation

## Goal

Сделать кнопки Music в NotchApp универсальным контроллером текущего macOS Now Playing-сеанса, включая Yandex Music, и устранить обрезание общего header на вкладке Music.

## Scope

- Заменить управление через K/N/P и Accessibility на команды, адресованные elected Now Playing player path.
- Поддержать `togglePlayPause`, `previousTrack` и `nextTrack` без bundle ID, координат, keyboard shortcuts и логики конкретного приложения.
- Считать команду доставленной только после callback MediaRemote с `sendError == 0`.
- Оставить текущую цепочку получения метаданных независимой от управления: MediaRemote info с generic Accessibility fallback.
- Выделить Music достаточную высоту через общую window sizing policy, не меняя размеры Limits, Calendar и Settings.

## Private API boundary

NotchApp динамически загружает `/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote` и не линкуется с private framework статически. Реализация использует локально подтверждённый ABI:

```text
MRMediaRemoteGetElectedPlayerPath(queue, callback(playerPath))
MRMediaRemoteSendCommandToPlayer(
    command,
    options,
    playerPath,
    0,
    queue,
    callback(sendError, handlerStatuses)
)
```

Команды используют системные ordinals `togglePlayPause = 2`, `nextTrack = 4`, `previousTrack = 5`. Путь игрока рассматривается как непрозрачный Objective-C object и живёт до завершения targeted send callback.

Private API разрешён владельцем проекта. Его отсутствие на другой версии macOS должно приводить к безопасному отказу команды, а не к crash или скрытому app-specific fallback.

## Control architecture

`MediaRemoteBridge` остаётся единственной границей с MediaRemote и дополнительно резолвит elected-path и targeted-send symbols. Внутренний testable transport принимает две операции:

1. Асинхронно получить elected player path.
2. Отправить mapped command этому path и вернуть delivery result.

`NowPlayingProvider.executeControlCommand` передаёт команду этому transport. После успешной доставки provider планирует существующий delayed metadata refresh. При неуспехе он не вызывает Accessibility control, не отправляет synthetic events и не выдаёт отправку за успех.

Старые `PlayerShortcutEvent`, `PlayerShortcutTransport` и control fallback через `AccessibilityNowPlayingSource.perform` удаляются. Сам `AccessibilityNowPlayingSource` сохраняется как metadata source.

## Result and error handling

Targeted send имеет следующие результаты:

- success: elected path получен, send callback вызван, `sendError == 0`;
- unavailable: private symbols отсутствуют;
- noPlayer: elected path равен `nil`;
- rejected: send callback вернул ненулевой `sendError`;
- timedOut: elected-path или send callback не завершился за одну секунду.

Повторных отправок и альтернативного транспорта нет. Следующее нажатие отменяет ожидание предыдущего на уровне provider, но callback-safe transport обязан корректно пережить поздний системный ответ.

## Layout contract

Причина обрезания header — фиксированное стандартное окно меньше суммы shared header, panel switcher, Now Playing card и footer. Header не получает Music-specific offset или padding.

`NotchWindowSizingPolicy` выбирает один из четырёх размеров:

- compact — существующий compact size;
- standard expanded — существующие 500×338 с физическим вырезом и 500×300 без него;
- Music expanded — 500×380 с физическим вырезом и 500×404 без него;
- Calendar month expanded — существующие 500×498 с физическим вырезом и 500×460 без него.

Music size применяется только когда приложение раскрыто, выбрана Music и встроенные Settings закрыты. Root view, expanded content и window coordinator используют одну policy, чтобы SwiftUI content frame и AppKit window не расходились.

## Testing

TDD regression coverage:

- каждая UI-команда отображается в правильный MediaRemote ordinal;
- transport сначала получает elected path и отправляет команду именно ему;
- `nil` path не вызывает send;
- `sendError != 0` не считается успехом;
- control flow не содержит Accessibility/shortcut fallback;
- sizing policy выбирает Music size только для раскрытой Music без Settings;
- существующие standard, Calendar и no-notch размеры не меняются.

После focused tests запускается весь `swift test`. Затем приложение собирается и подписывается существующим project script, запускается, и вручную проверяются стабильный header и Pause, Next, Previous в активном Yandex Music-сеансе.

## Non-goals

- Не менять способ чтения metadata или artwork.
- Не добавлять app-specific bundle IDs, названия процессов или player adapters.
- Не использовать Accessibility для control actions.
- Не имитировать media keys, K/N/P или другие keyboard events.
- Не менять визуальный дизайн Now Playing card, Limits, Calendar или Settings.
- Не добавлять retry, command queue или поддержку дополнительных MediaRemote-команд.

## Acceptance criteria

- Pause, Next и Previous управляют активным Yandex Music через elected Now Playing session.
- Те же кнопки используют тот же системный путь для любого другого elected player.
- Music header и gear полностью видимы в стабильном expanded state.
- Limits, Calendar и Settings сохраняют прежнюю геометрию и поведение.
- Focused и full test suites проходят; live success не заявляется без текущей runtime-проверки.
