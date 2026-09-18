import Foundation

enum LauncherResultAction: String, CaseIterable, Identifiable {
    case open, reveal, copyPath, processFile, renameFile, attachToAI, recognizeText
    case copy, paste, prepareAI, translate, explain, jiraStatus, jiraWorklog
    case saveSnippet, removeSnippet

    var id: Self { self }
    var title: String {
        switch self {
        case .open: "Открыть / применить"
        case .reveal: "Показать в Finder"
        case .copyPath: "Скопировать путь"
        case .processFile: "Обработать файл…"
        case .renameFile: "Переименовать…"
        case .attachToAI: "Прикрепить к новому AI-чату"
        case .recognizeText: "Распознать текст…"
        case .copy: "Скопировать"
        case .paste: "Вставить в предыдущее приложение"
        case .prepareAI: "Подготовить вопрос AI"
        case .translate: "Перевести с AI…"
        case .explain: "Объяснить с AI…"
        case .jiraStatus: "Изменить статус…"
        case .jiraWorklog: "Списать время…"
        case .saveSnippet: "Сохранить как шаблон"
        case .removeSnippet: "Удалить шаблон"
        }
    }
    var symbol: String {
        switch self {
        case .open: "arrow.up.forward"
        case .reveal: "folder"
        case .copyPath: "link"
        case .processFile: "wand.and.stars"
        case .renameFile: "pencil"
        case .attachToAI: "paperclip"
        case .recognizeText: "text.viewfinder"
        case .copy: "doc.on.doc"
        case .paste: "clipboard"
        case .prepareAI, .explain: "sparkles"
        case .translate: "character.bubble"
        case .jiraStatus: "arrow.triangle.2.circlepath"
        case .jiraWorklog: "clock"
        case .saveSnippet: "bookmark"
        case .removeSnippet: "trash"
        }
    }

    static func available(for result: LauncherResult, clipboardItem: LauncherClipboardItem? = nil) -> [Self] {
        switch result.payload {
        case .application: return [.open, .reveal, .copyPath]
        case .file(let url):
            var actions: [Self] = [.open, .reveal, .copyPath, .processFile, .renameFile]
            if AIChatAttachmentLoader.allowedExtensions.contains(url.pathExtension.lowercased()) { actions.append(.attachToAI) }
            if TextRecognitionService.supports(url: url) { actions.append(.recognizeText) }
            return actions
        case .clipboard:
            guard let clipboardItem else { return [] }
            return [.copy, .paste] + (clipboardItem.text?.isEmpty == false ? [.prepareAI, .translate, .explain, .saveSnippet] : [])
        case .snippet: return [.copy, .paste, .prepareAI, .translate, .explain, .removeSnippet]
        case .calculation: return [.copy, .prepareAI, .explain, .saveSnippet]
        case .nool(_, let kind):
            return kind == .jira ? [.open, .copy, .jiraStatus, .jiraWorklog] : [.open, .copy]
        case .windowAction, .windowLayout, .windowLayoutManager: return [.open]
        }
    }
}

struct LauncherJiraDestination: Identifiable {
    let id = UUID()
    let issue: JiraIssue
    let action: LauncherResultAction
}
