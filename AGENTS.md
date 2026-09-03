# AGENTS.md

Этот файл — оперативный контекст для разработчиков и coding agents. Читай его
перед изменениями в Nool Notch. Пользовательская документация находится в
`README.md`, история изменений — в `CHANGELOG.md`, а публикация релиза — в
`DEPLOY.md`.

## Быстрый старт

Проект — Swift Package для macOS 14+, основной executable называется
`NotchApp`. На рабочей машине обычно доступен Xcode beta:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcrun swift build
./scripts/run-app.sh
```

`run-app.sh` собирает `Build/NotchApp.app`, подписывает его, завершает старый
процесс и запускает новый bundle. Если стабильного сертификата нет, ad-hoc
подпись разрешается только явно:

```sh
NOTCHAPP_ALLOW_ADHOC=1 ./scripts/run-app.sh
```

Ad-hoc переподпись может сбросить Accessibility trust. Не меняй signing mode
без необходимости во время визуальной проверки Now Playing.

## Карта проекта

- `Package.swift` — SwiftPM targets `NotchCore`, `NotchApp`, `NotchAppTests`.
- `Sources/NotchCore` — общие модели квот без UI.
- `Sources/NotchApp/NotchApp.swift` — вход в приложение.
- `Sources/NotchApp/NotchWindowCoordinator.swift` — создание, позиционирование
  и внешняя геометрия `NSPanel`.
- `Sources/NotchApp/NotchRootView.swift` — compact/expanded transition,
  hover-policy и запуск сворачивания.
- `Sources/NotchApp/NotchViewModel.swift` — UI orchestration и состояние
  панелей.
- `Sources/NotchApp/AISessionStore.swift` — общий inbox и маршрутизация действий
  к источникам Codex Desktop и локальных CLI agents.
- `Sources/NotchApp/CodeReviewProvider.swift` — Git remote discovery и
  read-only GitHub/GitLab PR/MR через `gh`/`glab`.
- `Sources/NotchApp/AISessionsPanel.swift` — Agent Inbox, связанные Jira-задачи
  и inline PR/CI-действия для каждой AI-сессии.
- `Sources/NotchApp/CodexCLIHookServer.swift` и
  `CodexCLIHookInstaller.swift` — локальный Unix socket и безопасное подключение
  Codex CLI/Claude Code hooks.
- `Sources/NoolAgentBridge` — минимальный blocking hook executable, который
  возвращает решение ожидающему CLI-процессу.
- `Sources/NotchApp/JiraClient.swift` — HTTP-контракт Jira REST/Agile API.
- `Sources/NotchApp/JiraProvider.swift` — lifecycle, загрузка, кэш и mutations.
- `Sources/NotchApp/JiraPanel.swift` — режим `Мои` и основной список задач.
- `Sources/NotchApp/JiraPinnedPanel.swift` — закреплённые Jira-источники.
- `Sources/NotchApp/JiraPinnedSettingsView.swift` — управление закреплениями.
- `Sources/NotchApp/AppPreferences.swift` — несекретные настройки UserDefaults.
- `Sources/NotchApp/JiraCredentialStore.swift` — Jira-токен в Keychain.
- `Sources/NotchApp/NowPlayingProvider.swift` и
  `AccessibilityNowPlayingSource.swift` — метаданные и fallback плеера.
- `Tests/NotchAppTests` — provider, client, model и interaction tests.
- `Tests/Signing` — shell-проверки signing script.
- `CHANGELOG.md` — пользовательские изменения в `Unreleased` и по версиям.
- `scripts/run-app.sh` — локальная сборка и перезапуск.
- `scripts/package-release.sh` — arm64 release ZIP и SHA-256.
- `.github/workflows/release.yml` — публикация по тегу `v*`.

## Критичные архитектурные инварианты

### Геометрия окна

`NotchWindowCoordinator` — единственный владелец внешнего `NSPanel.frame`.
SwiftUI-контент не должен автоматически менять размер hosting window до
явного coordinator `setFrame`. Иначе при переходе `500×380 → 340×40`
компактный view на один кадр рисуется в старом нижнем левом углу, что выглядит
как скачок вниз и в сторону.

Окно всегда остаётся прибитым к верхнему центру выбранного экрана. Любые
изменения размеров проверяй в реальном AppKit-сценарии, а не только snapshot
или unit test.

### Popover и сворачивание

Jira status/worklog popover и другие transient surfaces должны закрываться до
сворачивания челки. `NotchViewModel.isTransientSurfaceVisible` участвует в
hover/collapse policy. Не запускай collapse параллельно с живым popover и не
обходи этот tracker прямой заменой SwiftUI-контента.

Обязательный ручной сценарий после изменений:

1. Раскрыть челку и открыть Jira.
2. Открыть status или worklog popover.
3. Кликнуть по пустой области рабочего стола.
4. Убедиться, что popover закрывается первым, а compact view не прыгает.

### Jira

- Режим `Мои` использует текущего пользователя и выбранные проекты.
- Закреплённые проекты и доски независимы от фильтров режима `Мои`.
- Доска показывает все задачи, возвращённые Jira Agile API; не добавляй
  фильтр по assignee или status.
- Каждый закреплённый проект или доска — отдельный source chip.
- Отдельно закреплённые issue keys отображаются одной строкой в `Задачи`.
- Порядок закреплений сохраняется в UserDefaults.
- Jira token хранится только в Keychain и никогда не логируется.
- Пагинация Jira обязательна: не считай первый response полным каталогом.
- Ошибка одного pinned source не должна ломать режим `Мои` или другие sources.

### Провайдеры и состояние

UI не выполняет сетевые запросы напрямую. Client отвечает за transport и
decode, provider — за lifecycle/state/cache, `NotchViewModel` — за UI-facing
команды. При обновлении сохраняй последнее успешное значение для loading/error
state там, где это уже предусмотрено моделью.

PR/CI не хранит и не логирует forge credentials. Для GitHub используй
авторизацию `gh`, для GitLab и custom/self-hosted GitLab — host-specific
авторизацию `glab`; хост определяется из remote репозитория.

### Agent Inbox

- `AISessionSource` — граница интеграции; новая IDE или CLI не должна добавлять
  provider-specific протокол в SwiftUI view.
- Ответ можно показывать в UI только при наличии живого
  `AISessionAttentionRequest`; read-only статус не является разрешением на
  выполнение действия.
- CLI bridge не логирует payload и слушает Unix socket только текущего
  пользователя. Не добавляй TCP listener или хранение prompt/response bodies.
- При изменении `~/.codex/hooks.json`, `~/.codex/config.toml` и
  `~/.claude/settings.json` сохраняй чужие записи и не перезаписывай
  неразбираемый конфиг. Managed entry определяется только по
  `nool-agent-bridge`.
- После изменений проверяй отдельно read-only discovery, blocking approval и
  fallback при закрытом Nool: сбой bridge не должен блокировать CLI навсегда.

## Рабочий процесс

Перед правками:

```sh
git fetch origin --prune
git status -sb
git log --oneline --decorate -8
```

Сохраняй чужие незакоммиченные изменения. Не используй `git reset --hard`,
force-push или массовое удаление. Для публичной работы ветка должна происходить
от свежего `origin/main`. Историческая `local/pre-public-history` имеет другую
цепочку commit и не должна пушиться напрямую в public `main`.

Ищи файлы и символы через `rg`/`rg --files`. Точечные изменения в файлах делай
через patch. Не добавляй реальный Jira URL, PAT, cookies, данные Keychain или
локальные account artifacts в source, tests, docs и logs.

Commit messages следуют Conventional Commits, например:

```text
feat(jira): add pinned sources
fix(window): anchor compact transition
docs: document release workflow
```

### Changelog и commit

Перед commit проверь `CHANGELOG.md`. Каждое изменение, заметное пользователю,
оператору установки или владельцу данных, должно быть описано в секции
`Unreleased` в том же commit, что и реализация. Это относится к новым функциям,
исправлениям поведения, изменениям UI, совместимости, разрешений, формата
хранения, установки и обновления.

Используй категории Keep a Changelog: `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, `Security`. Пиши коротко с точки зрения пользователя и не
перечисляй файлы или внутренние детали реализации. Не редактируй уже
опубликованные секции задним числом.

Отдельная запись не требуется для внутренних docs-only правок, тестов,
рефакторинга или CI housekeeping без изменения пользовательского и
операционного поведения. Если такая правка меняет установку, релизный процесс
или требования к окружению, она считается заметной и должна попасть в
`Unreleased`.

Перед релизом перенеси содержимое `Unreleased` в секцию
`[X.Y.Z] - YYYY-MM-DD`, создай новую пустую `Unreleased` и обнови comparison
links внизу файла. Release tag должен указывать на commit с этой версией
changelog.

## Проверка изменений

Минимум для любого изменения:

```sh
git diff --check
xcrun swift build
```

Полный Swift-набор:

```sh
xcrun swift test
```

Signing script:

```sh
Tests/Signing/sign-app.test.sh
```

Выбирай проверку пропорционально риску:

- docs-only: `git diff --check`, проверка ссылок и команд;
- models/client/provider: focused tests плюс `swift build`;
- окно, hover, popover, Now Playing: build, перезапуск и ручной AppKit-сценарий;
- release/signing: полный checklist из `DEPLOY.md`.

Не утверждай, что тесты прошли, если запускалась только сборка. Если владелец
проекта сознательно берёт живую проверку на себя, явно разделяй build evidence,
manual acceptance и непрогнанные tests.

## Release и Homebrew

Полный порядок находится в `DEPLOY.md`. Коротко:

1. Проверить clean `main` и собрать локальный production artifact.
2. Завершить release-секцию в `CHANGELOG.md` и commit её до тега.
3. Проверить version, checksum, ZIP, arm64 и codesign.
4. Push commit, затем push аннотированного `vX.Y.Z` tag.
5. Дождаться GitHub Actions или диагностировать его падение.
6. Проверить опубликованные assets повторным скачиванием.
7. Обновить `nail00749/homebrew-tap/Casks/nool-notch.rb`.
8. Выполнить `brew update`, `brew info` и `brew style`.

Известная проблема: Apple Swift 6.3.3 на runner `macos-26`/Xcode 26.6 может
падать в optimized build с `SmallVector unable to grow`. Ручной GitHub Release
допустим только из полностью проверенного локального артефакта. Не подменяй
assets существующего релиза и не передвигай опубликованный tag; выпускай новую
patch-версию.

Публичные releases пока ad-hoc signed и не notarized. Homebrew установка
требует `--no-quarantine`.

## Что не считать доказательством

- Успешный `swift build` не доказывает прохождение tests.
- Успешный upload не доказывает целостность удалённого ZIP.
- Зелёный unit test не доказывает отсутствие визуального скачка `NSPanel`.
- GitNexus reindex после commit не является build или runtime-проверкой.
- Наличие Jira issue в одном page не доказывает корректную пагинацию каталога.
