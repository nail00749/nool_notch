# Профилирование раскрытия чёлки

В debug-сборке доступен явный локальный сценарий: 8 раскрытий и сворачиваний
с текущими настройками приложения. В обычном запуске он не создаёт таймеров;
в release-сборке диагностический код отсутствует.

После `./scripts/run-app.sh` завершите запущенный NooL App и запустите:

```sh
NOOL_PROFILE_EXPANSION=1 \
NOOL_PROFILE_OUTPUT=/tmp/nool-expansion-profile.json \
./Build/NooL\ App.app/Contents/MacOS/NotchApp
```

Сценарий ждёт 8 секунд после запуска, измеряет каждое переключение в течение
650 мс и делает паузу 650 мс. По окончании display link отключается и записывается
JSON с интервалами callbacks без пользовательского содержимого. После серии
отдельно измеряются 3 секунды CPU в compact idle с отключённым display link.
Приложение остаётся работающим.
Повторный обычный запуск отключает сценарий. Во время серии не собирайте проект,
не запускайте тесты и не взаимодействуйте с чёлкой. Провайдеры остаются настоящими:
их обычная политика загрузки действует и во время замера.

`cpu_ms` — CPU time всего процесса, включая обои и другие включённые модули,
за измерительное окно; это не изолированная стоимость анимации.
`callback_gap_*` — интервалы доставки CADisplayLink на main run loop.
Большой интервал указывает на задержку доставки, но **не является доказанным
числом пропущенных экранных кадров**. Для реальных render hitches используйте
Instruments Animation Hitches; для стека — Time Profiler или `sample`.
Метки `Notch transition` в категории `ExpansionProfile` обозначают измерительные
окна, включая работу непосредственно после анимации.

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcrun xctrace record --template 'Animation Hitches' \
  --instrument 'Time Profiler' --instrument 'os_signpost' \
  --time-limit 35s --output /tmp/notch-expansion.trace \
  --env NOOL_PROFILE_EXPANSION=1 \
  --launch -- "$PWD/Build/NooL App.app/Contents/MacOS/NotchApp"
```

Не запускайте второй экземпляр поверх обычного. Перед сравнением используйте
одинаковые панель, настройки, дисплей и режим сборки. Debug-цифры нельзя выдавать
за характеристики optimized release. Ошибка подключения к DTServiceHub означает,
что созданный `.trace` нельзя считать успешным измерением кадров.
