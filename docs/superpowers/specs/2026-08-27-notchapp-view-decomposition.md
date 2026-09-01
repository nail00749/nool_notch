# NotchApp view decomposition

Status: approved for implementation

## Goal

Разделить крупные Swift-файлы NotchApp по ответственности, сохранив текущее поведение, внешний вид и публичные точки входа.

## Scope

- Разложить `NotchViews.swift` на файлы корневого view, compact/expanded notch, лимитов, календаря, настроек и общих UI-элементов.
- Разложить `NotchApp.swift` на lifecycle приложения, coordinator окна, panel и screen-positioning extension.
- Оставить все файлы в существующих SwiftPM targets без новых зависимостей и модулей.
- Сохранить имена типов, доступность (`private`/internal), порядок поведения и текущие импорты настолько, насколько это возможно без изменения семантики.

## Target layout

```text
Sources/NotchApp/
  NotchApp.swift
  NotchWindowCoordinator.swift
  NotchPanel.swift
  NSScreen+Notch.swift
  NotchRootView.swift
  CompactNotch.swift
  ExpandedNotch.swift
  LimitsPanel.swift
  CalendarPanel.swift
  NotchSettingsView.swift
  NotchSharedUI.swift
```

`NotchSharedUI.swift` содержит только реально общие layout constants, shapes, button style и color helpers. Вспомогательные view, используемые исключительно одной feature, остаются рядом с этой feature.

## Non-goals

- Не добавлять месячный режим календаря в рамках этого рефакторинга.
- Не менять модель данных, EventKit-запросы, quota providers, настройки или сохранение пользовательских параметров.
- Не менять размеры, анимации, маршрутизацию панелей, activation policy и поведение settings window.
- Не добавлять unit-тесты или внешние зависимости.

## Implementation order

1. Сначала вынести `NotchViews.swift` по ownership boundaries, сохраняя исходные тела типов.
2. Затем вынести window/AppKit-типы из `NotchApp.swift`.
3. Удалить ставшие пустыми исходные файлы/дубли и проверить, что target видит все новые файлы.

Каждый промежуточный шаг должен оставаться компилируемым; поведенческие изменения в этот refactor не входят.

## Verification boundary

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /usr/bin/xcrun swift build`
- `zsh -n scripts/run-app.sh`
- E2E запуск собранного `Build/NotchApp.app`: limits, calendar loading/denied/retry, music placeholder и settings должны открываться как раньше.

Остановиться после подтверждения сборки и этих сохранённых сценариев; месячный календарь планируется отдельным изменением.
