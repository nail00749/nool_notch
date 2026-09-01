# Nool Notch

Нативная macOS-челка с переключаемыми панелями:

- лимиты подписок ChatGPT, Claude Code и Ollama Cloud;
- универсальный Now Playing с обложкой и управлением воспроизведением;
- ближайшие события календаря;
- задачи Jira с подключением своего инстанса;
- компактная цветная линия недельного лимита.

Приложение рассчитано на macOS 14+. На MacBook используется физическая
челка; на внешнем дисплее или Mac без выреза отображается программный вариант.

## Установка через Homebrew

Первый релиз собран для Mac с Apple Silicon и подписан ad-hoc. Пока у проекта
нет Developer ID и нотаризации, при установке нужно явно отключить quarantine:

```sh
brew tap nail00749/tap
brew install --cask --no-quarantine nool-notch
```

После установки запусти `NotchApp` из `/Applications` и выдай запрошенные
разрешения в System Settings. Обновление будет доступно обычной командой
`brew upgrade --cask nool-notch`.

## Сборка из исходников

Понадобятся Xcode или Xcode Command Line Tools со Swift 6:

```sh
git clone https://github.com/nail00749/nool_notch.git
cd nool_notch
./scripts/run-app.sh
```

Скрипт собирает executable, упаковывает его в `Build/NotchApp.app`, подписывает
и запускает приложение. Если на Mac нет локального Apple Development
сертификата, разреши временную ad-hoc подпись явно:

```sh
NOTCHAPP_ALLOW_ADHOC=1 ./scripts/run-app.sh
```

Ad-hoc подпись подходит для локальной сборки, но после пересборки macOS может
повторно запросить Accessibility-разрешение. Для стабильной локальной подписи
можно передать имя своего сертификата через `NOTCHAPP_SIGNING_IDENTITY`.

## Разрешения и данные

- Accessibility используется как fallback для метаданных активного плеера.
- Доступ к календарю запрашивается только для отображения ближайших событий.
- Jira-токен хранится в macOS Keychain.
- NotchApp читает существующую авторизацию Claude Code только в памяти и не
  сохраняет токен у себя.

## Структура

- `Sources/NotchCore` — независимые модели панелей и квот.
- `Sources/NotchApp` — SwiftUI-интерфейс и AppKit-координатор окна.
- `Tests` — Swift- и shell-проверки.
- `scripts` — сборка, упаковка, подпись и запуск.
- `docs` — спецификации и планы развития.

## Релизы

Тег вида `vX.Y.Z` запускает GitHub Actions: workflow собирает arm64 executable,
создаёт ad-hoc signed `NotchApp.app`, упаковывает ZIP и публикует GitHub Release
вместе с SHA-256 checksum.
