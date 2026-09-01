# Jira task panel

Status: approved for implementation

## Goal

Добавить в NotchApp отдельную вкладку Jira для просмотра открытых задач текущего пользователя, фильтрации по проектам, открытия задач в браузере и выполнения доступных workflow transitions в существующей Jira Server/Data Center.

Интеграция подключается напрямую к REST API v2 через Base URL и Personal Access Token. Она не зависит от Limits, Calendar, Music или их providers.

## Product scope

- Новая вкладка `Jira` в общем panel switcher.
- Базовый набор задач определяется JQL `assignee = currentUser() AND resolution IS EMPTY`.
- Пользователь может выбрать один или несколько проектов; пустой выбор означает все доступные проекты.
- Список показывает до 50 задач, отсортированных по priority и времени обновления.
- Нажатие на задачу открывает её стандартную страницу Jira в браузере.
- Нажатие на статус загружает актуальные transitions и позволяет выполнить один из них.
- Список обновляется при открытии вкладки, вручную и раз в 60 секунд, пока Jira видима.

## Architecture

Интеграция разделяется на четыре слоя:

1. `JiraClient` формирует HTTP-запросы, декодирует Jira DTO и нормализует transport/API errors.
2. `JiraProvider` владеет состоянием проектов, выбранного фильтра, задач, refresh lifecycle и transition operations.
3. `JiraCredentialStore` хранит PAT в macOS Keychain за тестируемым протоколом.
4. `JiraPanel` и Jira-секция Settings отображают состояние и отправляют пользовательские намерения provider-у.

`NotchViewModel` связывает panel visibility, settings и provider, но не содержит HTTP, Keychain или JQL-логику. `PanelID.jira` остаётся самостоятельным модулем в существующем panel registry.

Production implementation использует `URLSession`, Swift Concurrency, `Security`/Keychain и `NSWorkspace`. Внешние зависимости не добавляются.

## Connection and credentials

Jira Settings содержит:

- Base URL, включая возможный path prefix, например `https://jira.example.com/jira`;
- SecureField для нового PAT;
- `Проверить подключение`;
- `Сохранить`;
- `Отключить`.

PAT хранится только как Keychain generic password. Base URL и выбранные project keys являются несекретными и сохраняются через существующий preferences store. Сохранённый PAT не читается обратно в UI: интерфейс показывает только факт наличия credential и позволяет заменить или удалить его.

Проверка подключения вызывает `GET /rest/api/2/myself`. `Сохранить` доступно только после валидного URL и успешной проверки введённых данных. `Отключить` удаляет PAT и Jira-настройки после явного действия пользователя.

URL строятся относительно нормализованного Base URL без потери его path prefix. PAT отправляется как `Authorization: Bearer <PAT>` только тому же scheme/host/port. Cross-origin redirects блокируются. TLS использует системное доверие macOS; bypass для недоверенных сертификатов не добавляется.

PAT, Authorization header и response bodies с потенциально чувствительными данными не пишутся в логи или пользовательские ошибки.

## Jira REST contract

Первая версия использует Jira Server/Data Center REST API v2:

- `GET /rest/api/2/myself` — проверка credential;
- `GET /rest/api/2/project` — доступные проекты;
- `POST /rest/api/2/search` — задачи;
- `GET /rest/api/2/issue/{key}/transitions` — доступные переходы;
- `POST /rest/api/2/issue/{key}/transitions` — выполнение перехода.

Search body содержит безопасно сформированный JQL:

```text
assignee = currentUser() AND resolution IS EMPTY
AND project IN ("APP", "WEB")
ORDER BY priority DESC, updated DESC
```

Project clause отсутствует для фильтра `Все`. Project keys поступают от Jira, дополнительно экранируются при формировании JQL и не интерполируются как произвольный пользовательский текст. Search запрашивает максимум 50 элементов и только необходимые fields: summary, status/statusCategory, priority, project, duedate и updated.

Transition POST использует Jira transition ID:

```json
{"transition":{"id":"31"}}
```

Названия статусов и переходов не хардкодятся. После успешного POST provider обновляет строку задачи и затем тихо синхронизирует список. Автоматического retry для transition POST нет.

## Data and state model

UI-модель задачи содержит:

- immutable Jira `id` и `key`;
- `summary`;
- project key/name;
- status id/name и status category key;
- optional priority;
- optional due date;
- updated timestamp;
- browser URL, вычисленный из Base URL и issue key.

Отсутствующие optional fields не делают весь ответ невалидным. Некорректная обязательная структура приводит к контролируемой decode error.

Provider публикует отдельные состояния:

- connection: not configured, validating, connected, authentication failure;
- list: idle, loading, loaded, empty, failed;
- transition loading/error по issue key, чтобы одна операция не блокировала весь список.

Каждый новый refresh отменяет предыдущий. Generation/request identity не позволяет позднему ответу заменить более свежие данные. При уходе с Jira-вкладки 60-секундный polling прекращается; при возврате выполняется свежий запрос.

## Panel design

Выбран вариант A — компактная рабочая очередь.

```text
+--------------------------------------------------+
| Jira                         [Refresh] [Settings] |
| [All] [APP] [WEB] [MOBILE]                      |
|--------------------------------------------------|
| | APP-184  Fix login timeout      [In progress v]|
| | High priority                         Today    |
|--------------------------------------------------|
| | WEB-72   Update billing page        [Review v]|
+--------------------------------------------------+
```

Панель использует тот же expanded height budget, что Music. Project chips горизонтально прокручиваются и поддерживают multi-select; `Все` очищает выбор. Сохранённый выбор восстанавливается при следующем запуске.

Каждая task row содержит:

- узкую status-category полосу;
- issue key моноширинным системным шрифтом;
- summary максимум в две строки;
- optional priority и due date;
- status control с chevron.

Клик по строке открывает задачу через `NSWorkspace`. Status control является отдельной hit area: он загружает transitions при каждом открытии и показывает локальный progress. Переход применяется только после выбора меню; optimistic status update не используется.

Визуальный язык сохраняет существующие material, typography и spacing NotchApp. Jira blue применяется только для активных Jira-действий. Status colors определяются Jira category (`new`, `indeterminate`, `done`), а неизвестная category получает нейтральный semantic color. Кастомные имена статусов не участвуют в выборе цвета.

## Empty, loading and error states

- Not configured: объяснение и `Подключить Jira`, открывающее Jira Settings.
- Loading: компактные placeholder rows без скачка общей геометрии.
- Empty: `Открытых задач нет` с доступными project chips и refresh.
- Authentication failure: `PAT недействителен` и переход в Jira Settings.
- Forbidden: `Недостаточно прав для этого действия`.
- Rate limited: `Jira временно ограничила запросы`; ручной retry остаётся доступным после ответа.
- Network/server failure: конкретное безопасное описание и `Повторить`.
- More than 50 results: список ограничен 50 задачами и явно показывает, что есть дополнительные результаты.

Ошибочный transition не меняет текущий status. Ошибка относится только к затронутой строке и не уничтожает уже загруженный список.

## Testing

Тесты работают через injected client/session and credential-store contracts и проверяют observable behavior:

- Base URL с path prefix корректно соединяется с `/rest/api/2` endpoints;
- Bearer header используется на same-origin запросах и не утекает через redirect;
- PAT не сохраняется в preferences и не появляется в отображаемой ошибке;
- JQL без project selection и с безопасно экранированным multi-project selection;
- decoding задач с отсутствующими priority/due date и с custom status names;
- загрузка проектов и восстановление выбранных keys;
- mapping 401, 403, 429, network и server errors;
- refresh cancellation и newest-request-wins;
- transitions загружаются по issue key, POST использует выбранный ID;
- failed transition не меняет status и не повторяет POST автоматически;
- successful transition обновляет строку и инициирует list reconciliation;
- Jira polling работает только для видимой вкладки;
- `PanelID.jira`, panel switching и Jira expanded sizing не меняют существующие Limits, Calendar, Music и Settings contracts.

После focused tests запускается полный `swift test`, signing regression, signed build/launch и визуальная проверка Jira-panel states. Live acceptance выполняется только после ввода владельцем Base URL/PAT и включает проверку подключения, загрузку реальной задачи, project filter, открытие browser URL и один разрешённый transition.

## Non-goals

- Создание или редактирование issue fields.
- Комментарии, attachments, worklogs и assignee changes.
- Board/sprint UI или локальный Kanban.
- Несколько Jira-инсталляций.
- Saved Jira filters и произвольный JQL editor.
- Offline cache, notifications и background polling при скрытой Jira.
- SSO/browser-cookie authentication.
- TLS trust bypass.
- Автоматические retry для state-changing requests.

## Acceptance criteria

- Пользователь подключает Jira Server/Data Center через Base URL и PAT без сохранения секрета вне Keychain.
- Вкладка показывает до 50 его unresolved issues и фильтрует их по выбранным проектам.
- Issue открывается в браузере по корректному URL с учётом Jira path prefix.
- Status menu показывает актуальные server-provided transitions и успешно выполняет выбранный переход.
- Ошибки авторизации, прав, rate limit, сети и transition не разрушают существующий список и дают понятное следующее действие.
- Jira refresh/polling не работает, когда вкладка скрыта.
- Limits, Calendar, Music, Settings, signing и существующее окно сохраняют прежнее поведение.
- Focused и full suites проходят; live Jira success не заявляется без текущей runtime-проверки.
