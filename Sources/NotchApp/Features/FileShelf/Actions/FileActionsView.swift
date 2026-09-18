import AppKit
import SwiftUI

/// UI for transforming the current File Shelf selection. `FileActionStore` owns
/// file access, output creation, cancellation, and rename planning.
struct FileActionsView: View {
    @ObservedObject var store: FileActionStore

    private let operations: [FileActionKind] = [
        .compressImage,
        .resizeImage,
        .convertPNG,
        .convertJPEG,
        .imagesToPDF,
        .rename
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                inputFiles

                if store.isRunning {
                    processingState
                } else {
                    operationPicker
                    operationOptions
                    if store.kind != .rename {
                        sizeOptions
                        outputDestination
                    }
                    actionArea
                }

                if let error = store.errorMessage {
                    errorMessage(error)
                }

                if !store.outputURLs.isEmpty {
                    results
                }
            }
            .padding(22)
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 42, height: 42)
                .background(NotchPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Действия с файлами")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(store.selectionSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var inputFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.kind == .imagesToPDF ? "Порядок страниц PDF" : "Выбранные файлы")
                .font(.system(size: 13, weight: .semibold))

            if store.inputURLs.isEmpty {
                Text("Добавьте файлы на полку, затем откройте это действие.")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(store.inputURLs.enumerated()), id: \.element) { index, url in
                        HStack(spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(NotchPalette.secondary)
                                .frame(width: 20, height: 20)
                                .background(NotchPalette.surface.opacity(0.72), in: Circle())
                            Image(systemName: fileIcon(for: url))
                                .foregroundStyle(NotchPalette.accent)
                                .frame(width: 16)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 32)
                        .background(NotchPalette.surface.opacity(0.56), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(NotchPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var operationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Операция")
                .font(.system(size: 13, weight: .semibold))
            Picker("Операция", selection: $store.kind) {
                ForEach(operations, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Действие с файлами")
        }
    }

    @ViewBuilder
    private var operationOptions: some View {
        switch store.kind {
        case .resizeImage:
            qualityOptions
        case .compressImage, .convertJPEG:
            qualityOptions
        case .rename:
            optionCard(title: "Новые имена", icon: "textformat") {
                HStack {
                    Text("Префикс")
                        .font(.system(size: 12))
                    TextField("Например, screenshot", text: renamePrefix)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Префикс имени")
                }
                HStack {
                    Text("Начать с")
                        .font(.system(size: 12))
                    Spacer()
                    TextField("1", value: startNumber, format: .number)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                        .accessibilityLabel("Начальный номер")
                }
                Text("Номера от 1 до 999 999. Перед переименованием будет показан список изменений.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
            }
        case .convertPNG, .imagesToPDF:
            EmptyView()
        }
    }

    private var sizeOptions: some View {
        optionCard(title: "Размер изображения", icon: "arrow.up.left.and.arrow.down.right") {
            HStack {
                Text("Максимальная сторона").font(.system(size: 12))
                Spacer()
                TextField("1920", value: maximumDimension, format: .number)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 86)
                    .accessibilityLabel("Максимальная сторона в пикселях")
                Text("px").font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
            }
            Text("От 1 до 4 096 px, без увеличения. Используется первый кадр; метаданные не сохраняются.")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
        }
    }

    private var qualityOptions: some View {
        optionCard(title: "Качество JPEG", icon: "dial.medium") {
            HStack(spacing: 12) {
                Slider(value: jpegQuality, in: 0.1...1, step: 0.05)
                    .tint(NotchPalette.accent)
                    .accessibilityLabel("Качество JPEG")
                Text("\(Int(store.options.jpegQuality * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchPalette.text)
                    .frame(width: 38, alignment: .trailing)
            }
            Text("Чем ниже значение, тем меньше размер файла.")
                .font(.system(size: 10))
                .foregroundStyle(NotchPalette.secondary)
        }
    }

    private var outputDestination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Куда сохранить")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .foregroundStyle(NotchPalette.accent)
                Text(store.outputDirectory?.path ?? "Рядом с исходными файлами")
                    .font(.system(size: 11))
                    .foregroundStyle(store.outputDirectory == nil ? NotchPalette.secondary : NotchPalette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Выбрать…", action: store.chooseOutputDirectory)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Выбрать папку для результата")
            }
            if store.kind != .rename {
                Text("Исходные файлы сохранятся без изменений.")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
            }
        }
        .padding(14)
        .background(NotchPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var actionArea: some View {
        if store.kind == .rename {
            VStack(alignment: .leading, spacing: 10) {
                Button("Предпросмотр", action: store.previewRename)
                    .buttonStyle(.bordered)
                    .disabled(store.inputURLs.isEmpty)

                if !store.renamePlan.isEmpty {
                    renamePreview
                    Button("Переименовать \(store.renamePlan.count) \(fileCountText(store.renamePlan.count))", action: store.applyRename)
                        .buttonStyle(.borderedProminent)
                        .tint(NotchPalette.accent)
                        .disabled(store.inputURLs.isEmpty)
                }
            }
        } else {
            Button(store.kind == .imagesToPDF ? "Создать PDF" : "Создать копии", action: store.run)
                .buttonStyle(.borderedProminent)
                .tint(NotchPalette.accent)
                .disabled(store.inputURLs.isEmpty)
        }
    }

    private var renamePreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Будут переименованы")
                .font(.system(size: 12, weight: .semibold))
            ForEach(store.renamePlan, id: \.id) { entry in
                HStack(spacing: 8) {
                    Text(entry.source.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchPalette.secondary)
                    Text(entry.destination.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(NotchPalette.accent)
                }
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .background(Color.signalAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var processingState: some View {
        HStack(spacing: 11) {
            ProgressView()
                .controlSize(.small)
                .tint(NotchPalette.accent)
            Text("Обрабатываю файлы…")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            Button("Отменить", action: store.cancel)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(NotchPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NotchPalette.text.opacity(0.85))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.signalAmber.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Готово", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.signalMint)
                Spacer()
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(store.outputURLs)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            ForEach(store.outputURLs, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(Color.signalMint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func optionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchPalette.text)
            content()
        }
        .padding(14)
        .background(NotchPalette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var maximumDimension: Binding<Int> {
        Binding(
            get: { store.options.maxDimension },
            set: { store.options.maxDimension = min(max($0, 1), 4_096) }
        )
    }

    private var jpegQuality: Binding<Double> {
        Binding(
            get: { store.options.jpegQuality },
            set: { store.options.jpegQuality = min(max($0, 0.1), 1) }
        )
    }

    private var renamePrefix: Binding<String> {
        Binding(
            get: { store.options.renamePrefix },
            set: { store.options.renamePrefix = String($0.prefix(120)) }
        )
    }

    private var startNumber: Binding<Int> {
        Binding(
            get: { store.options.startNumber },
            set: { store.options.startNumber = min(max($0, 1), 999_999) }
        )
    }

    private func fileIcon(for url: URL) -> String {
        let extensionName = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff"].contains(extensionName)
            ? "photo"
            : "doc"
    }

    private func fileCountText(_ count: Int) -> String {
        let remainder = count % 100
        if (11...14).contains(remainder) { return "файлов" }
        switch count % 10 {
        case 1: return "файл"
        case 2...4: return "файла"
        default: return "файлов"
        }
    }
}
