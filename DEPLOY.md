# Публикация Nool Notch

Этот runbook описывает выпуск GitHub Release и обновление Homebrew cask.
Основной репозиторий: `nail00749/nool_notch`. Homebrew tap:
`nail00749/homebrew-tap`.

## 1. Предварительная проверка

Релиз создаётся только из свежего публичного `main`. Не отправляй в public
исторические локальные ветки вроде `local/pre-public-history`: сначала перенеси
нужные commit поверх `origin/main`.

```sh
git fetch origin --prune
git status --short
git switch main
git pull --ff-only origin main
git log --oneline --decorate -5
gh auth status
xcrun swift --version
```

Перед продолжением рабочее дерево должно быть чистым, а `HEAD` — совпадать с
commit, который будет помечен тегом. Убедись, что в diff нет токенов, cookies,
локальных URL или других секретов.

Проверь `CHANGELOG.md`: все заметные изменения после прошлого тега должны быть
описаны в `Unreleased`. Не выпускай код с отсутствующей пользовательской
записью, даже если commit и build уже готовы.

Минимальная проверка исходников:

```sh
git diff --check
xcrun swift build
```

Для рискованных изменений запусти соответствующие focused tests или полный
набор:

```sh
xcrun swift test
```

Если тесты намеренно пропущены, это нужно явно указать в итогах релиза.

## 2. Выбор версии и локальный release-артефакт

Версии следуют формату `X.Y.Z`. Далее в примерах используется переменная:

```sh
NOTCHAPP_VERSION=0.1.4
```

До сборки релиза подготовь changelog:

1. Перенеси записи из `Unreleased` в `[X.Y.Z] - YYYY-MM-DD`.
2. Создай сверху новую пустую секцию `Unreleased`.
3. Обнови ссылки `[Unreleased]` и новой версии внизу файла.
4. Не изменяй содержание уже опубликованных версий.

```sh
git diff --check CHANGELOG.md
git add CHANGELOG.md
git commit -m "docs(changelog): release ${NOTCHAPP_VERSION}"
```

Именно этот commit должен быть собран, отправлен в `main` и помечен release
tag. Если `Unreleased` пуст, сначала убедись, что релиз действительно не
содержит пользовательских изменений.

Проверь, что версия и тег ещё свободны:

```sh
git tag --list "v${NOTCHAPP_VERSION}"
git ls-remote --tags origin "refs/tags/v${NOTCHAPP_VERSION}"
gh release view "v${NOTCHAPP_VERSION}"
```

Собери тот же arm64-артефакт, который использует release workflow:

```sh
./scripts/package-release.sh "$NOTCHAPP_VERSION"
```

Проверь результат до создания тега:

```sh
cd dist
shasum -a 256 -c "NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip.sha256"
unzip -t "NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip"
plutil -p NotchApp.app/Contents/Info.plist
file NotchApp.app/Contents/MacOS/NotchApp
codesign --verify --deep --strict --verbose=2 NotchApp.app
cd ..
```

Ожидаемый результат:

- checksum имеет статус `OK`;
- ZIP не содержит ошибок;
- `CFBundleShortVersionString` совпадает с релизной версией;
- executable имеет архитектуру `arm64`;
- `NotchAppSigningMode` равен `ad-hoc` для публичного артефакта;
- `codesign` подтверждает designated requirement.

## 3. Push и тег

Сначала отправь commit в `main`, затем создай аннотированный тег на том же
commit:

```sh
git push origin HEAD:main
git tag -a "v${NOTCHAPP_VERSION}" -m "Nool Notch v${NOTCHAPP_VERSION}"
git push origin "v${NOTCHAPP_VERSION}"
```

Проверь, что `origin/main` и тег указывают на ожидаемый commit:

```sh
git rev-parse HEAD
git ls-remote origin refs/heads/main "refs/tags/v${NOTCHAPP_VERSION}"
```

## 4. GitHub Actions и ручной fallback

Тег запускает `.github/workflows/release.yml`:

```sh
gh run list --repo nail00749/nool_notch --workflow Release --limit 5
gh run watch RUN_ID --repo nail00749/nool_notch --exit-status
```

На runner `macos-26` с Xcode 26.6 уже наблюдался crash Apple Swift 6.3.3:

```text
SmallVector unable to grow
fatal error encountered during compilation
```

Это crash компилятора на этапе optimized build, а не доказательство ошибки
исходников. Если workflow упал, сначала прочитай точный лог:

```sh
gh run view RUN_ID --repo nail00749/nool_notch --log-failed
```

Ручная публикация допустима только когда локальный production-артефакт прошёл
все проверки из раздела 2. Не перезаписывай assets существующего релиза.

```sh
gh release create "v${NOTCHAPP_VERSION}" \
  "dist/NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip" \
  "dist/NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip.sha256" \
  --repo nail00749/nool_notch \
  --verify-tag \
  --title "Nool Notch v${NOTCHAPP_VERSION}" \
  --generate-notes
```

## 5. Проверка опубликованного релиза

Не полагайся только на успешный upload: скачай assets обратно и повторно
проверь их.

```sh
NOTCHAPP_VERIFY_DIR="$(mktemp -d /private/tmp/notchapp-release.XXXXXX)"
gh release download "v${NOTCHAPP_VERSION}" \
  --repo nail00749/nool_notch \
  --dir "$NOTCHAPP_VERIFY_DIR"
cd "$NOTCHAPP_VERIFY_DIR"
shasum -a 256 -c "NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip.sha256"
unzip -t "NoolNotch-v${NOTCHAPP_VERSION}-arm64.zip"
```

Сохрани SHA-256 ZIP — он нужен для Homebrew cask.

## 6. Обновление Homebrew tap

Клонируй tap в отдельный временный каталог:

```sh
NOTCHAPP_TAP_DIR="$(mktemp -d /private/tmp/nool-homebrew-tap.XXXXXX)"
git clone https://github.com/nail00749/homebrew-tap.git "$NOTCHAPP_TAP_DIR/tap"
cd "$NOTCHAPP_TAP_DIR/tap"
```

В `Casks/nool-notch.rb` измени только `version` и `sha256`. URL уже использует
версию динамически. Затем проверь и отправь commit:

```sh
git diff --check
ruby -c Casks/nool-notch.rb
git add Casks/nool-notch.rb
git commit -m "chore: update Nool Notch to ${NOTCHAPP_VERSION}"
git push origin main
```

Обнови локальные Homebrew metadata и проверь опубликованный cask:

```sh
brew update
brew info --cask nail00749/tap/nool-notch
brew style --cask nail00749/tap/nool-notch
```

Версия в `brew info`, версия GitHub Release и SHA-256 должны совпадать.

## 7. Rollback

Не перемещай опубликованный тег и не подменяй assets под существующей версией.
Если релиз неисправен:

1. Верни cask на предыдущую рабочую версию и checksum отдельным commit в tap.
2. Исправь приложение в новом commit.
3. Выпусти новую patch-версию.
4. Обнови cask на новый неизменяемый релиз.

До появления Developer ID публичные сборки остаются ad-hoc signed. Установка
через Homebrew требует `--no-quarantine`; это ожидаемое ограничение, а не повод
отключать дополнительные проверки подписи.
