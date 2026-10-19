# Управление дисплеями — план

Цель: базовое управление мониторами в духе BetterDisplay / Crisp прямо из
челки. Этап 1 использует только публичные API CoreGraphics; приватные
DisplayServices и DDC (IOAVService) — этап 2.

Проверено на macOS 27.2 arm64: все нужные публичные и приватные символы
доступны (`IOAVService*`, `DisplayServices*Brightness`,
`SLSConfigureDisplayEnabled`, `CGVirtualDisplay*`).

## Структура

```
Features/Displays/
  DisplayModels.swift                // DisplayInfo, DisplayModeOption, ключ по UUID
  DisplayConfigurationService.swift  // единственная граница с CoreGraphics
  DisplayBrightnessService.swift     // gamma / DisplayServices / DDC (этап 2)
  DisplayFeatureModel.swift          // @MainActor, состояние + команды для UI
  DisplayRevertController.swift      // «Оставить режим?» + таймер отката
  DisplaysPanel.swift                // UI в челке
  DisplaySettingsView.swift          // раздел настроек
```

SwiftUI не обращается к CoreGraphics: view → `DisplayFeatureModel` → service.
Сервисы закрыты протоколами, чтобы тесты подставляли fake.

## 1. Список дисплеев и отслеживание изменений

- `CGGetOnlineDisplayList`, `CGDisplayIsBuiltin`, `CGDisplayIsMain`,
  `CGDisplayMirrorsDisplay`.
- Стабильный ключ для сохранения: `CGDisplayCreateUUIDFromDisplayID(id)`.
  `CGDirectDisplayID` может меняться после переподключения.
- Имя: `NSScreen.localizedName`, сопоставление через
  `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`.
- Изменения: `CGDisplayRegisterReconfigurationCallback`. В callback
  пропускать `.beginConfigurationFlag`, затем переходить на main actor.
  Можно и через `NSApplication.didChangeScreenParametersNotification`.

## 2. Режимы: разрешение, HiDPI, частота

```swift
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] ?? []
```

- Фильтр `mode.isUsableForDesktopGUI()`.
- HiDPI: `mode.pixelWidth > mode.width`.
- Дедупликация по `(width, height, refreshRate, isHiDPI)`, без неё в списке
  будут дубли, отличающиеся только `ioFlags`.
- Текущий режим: `CGDisplayCopyDisplayMode(id)`.
- В UI группировать по «виду как» (`width×height`), частоту и HiDPI выбирать
  внутри группы.

## 3. Применение режима с откатом

```swift
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
CGCompleteDisplayConfiguration(cfg, .forSession)   // пробный режим
```

- Перед применением запомнить предыдущий `CGDisplayMode`.
- `DisplayRevertController` показывает «Оставить? Откат через 15 с» по центру
  того же дисплея; координаты пересчитывать после смены режима.
- Подтверждение → повторно применить режим с `.permanently`.
  Таймаут или «Отменить» → вернуть предыдущий режим.
- Если дисплей отключили во время таймера, откат отменяется без ошибок.
- `CGError != .success` → показать ошибку и ничего не сохранять.

## 4. Главный дисплей и зеркалирование

- Сделать главным: в одной транзакции `CGConfigureDisplayOrigin(cfg, newMain, 0, 0)`,
  остальные дисплеи сдвинуть на `-origin` нового главного.
- Зеркалирование: `CGConfigureDisplayMirrorOfDisplay(cfg, id, master)`,
  выключение — `kCGNullDirectDisplay`.
- Те же изменения проходят через `DisplayRevertController`.

## 5. Программное затемнение (gamma)

```swift
CGSetDisplayTransferByTable(id, 256, red, green, blue) // исходные таблицы × factor
```

- Базовые таблицы брать из `CGGetDisplayTransferByTable` при старте, чтобы
  сохранить калибровку.
- При выходе вызывать `CGDisplayRestoreColorSyncSettings()`. macOS сбрасывает
  gamma после сна и смены профиля, поэтому значение применять повторно
  (`NSWorkspace.didWakeNotification`, screen parameters changed).
- Нижняя граница фактора около 0.1, чтобы экран не стал полностью чёрным.

## 6. Яркость (этап 2)

Приватные символы подгружаются лениво через `dlopen`/`dlsym`, без статической
линковки. Нет символа — возможность скрыта в UI.

**Встроенный экран** — `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`:

```swift
typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
// "DisplayServicesGetBrightness" / "DisplayServicesSetBrightness"
```

**Внешний монитор, DDC/CI** — `IOAVServiceCreateWithService`,
`IOAVServiceWriteI2C`, `IOAVServiceReadI2C` из IOKit:

- Сервисы: обход IORegistry, класс `DCPAVServiceProxy` с `Location == "External"`.
- Сопоставление с `CGDirectDisplayID` — самая нетривиальная часть: сравнивать
  EDID/vendor/product/serial с `CGDisplayVendorNumber`, `CGDisplayModelNumber`,
  `CGDisplaySerialNumber` (см. `Arm64DDC.swift` в MonitorControl).
- Пакет записи:

```swift
// IOAVServiceWriteI2C(svc, 0x37, 0x51, &data, 6)
let data: [UInt8] = [0x84, 0x03, vcp, UInt8(v >> 8), UInt8(v & 0xFF), chk]
// chk = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ vcp ^ hi ^ lo
// VCP: 0x10 яркость, 0x12 контраст, 0x62 громкость
```

- Все DDC-вызовы вне main actor, на последовательной очереди, с timeout.
  Слайдер с debounce 50–100 мс, иначе часть мониторов зависает.
- DDC не отвечает → fallback на gamma-затемнение из пункта 5.

## UI

- Вкладка в челке: на каждый дисплей имя, слайдер яркости/затемнения и меню
  режимов.
- Команды Launcher: «Разрешение 1920×1080», «Главный дисплей …».
- Настройки: включение модуля, затемнение по умолчанию, восстановление режимов
  после переподключения (по UUID, в `AppPreferences`).

## Не входит в MVP

`SLSConfigureDisplayEnabled` (вкл/выкл экранов), `CGVirtualDisplay` (свои
HiDPI-разрешения), XDR/EDR-буст, перехват клавиш яркости (требует Input
Monitoring).

## Проверка

- Unit tests на fake-сервисе: фильтр и дедупликация режимов, логика отката
  (таймер, подтверждение, исчезнувший дисплей), gamma-таблицы, контрольная
  сумма DDC.
- Вручную:
  - сменить режим и дождаться отката;
  - сменить режим, подтвердить и перелогиниться;
  - отключить монитор во время таймера;
  - затемнение сохраняется после сна и сбрасывается при выходе из NooL;
  - челка остаётся по центру после смены разрешения главного экрана
    (`NotchWindowCoordinator` пересчитывает позицию на screen parameters change).
- `CHANGELOG.md`: запись в `Unreleased → Added`.
