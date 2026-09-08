import AppKit
import SwiftUI

struct FileShelfPanel: View {
    @ObservedObject var store: FileShelfStore
    var onChooseFiles: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            header

            if store.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { item in
                            FileShelfRow(item: item) {
                                store.remove(item)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
            }

            if store.isImporting {
                Label("Добавляю файлы…", systemImage: "arrow.down.doc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.signalMint.opacity(0.85))
            }

            if let error = store.errorMessage {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.signalAmber)
                    Text(error)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: store.dismissError) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(NotchButtonStyle())
                    .foregroundStyle(.white.opacity(0.52))
                    .accessibilityLabel("Закрыть ошибку")
                }
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.signalAmber.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .frame(width: 500)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.signalMint)

            Text("Файлы")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            Text("\(store.items.count)/\(FileShelfStore.maximumItemCount)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))

            Spacer(minLength: 8)

            if let onChooseFiles {
                Button(action: onChooseFiles) {
                    Label("Выбрать", systemImage: "plus")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(Color.signalMint)
                .background(Color.signalMint.opacity(0.14), in: Capsule())
                .accessibilityLabel("Выбрать файлы")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Color.signalMint)
            Text("Временная полка пуста")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
            Text("Перетащите файлы на чёлку или выберите их здесь")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
        }
    }
}

private struct FileShelfRow: View {
    let item: FileShelfItem
    let onRemove: () -> Void

    private var iconName: String {
        (try? item.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? "folder.fill"
            : "doc.fill"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.signalMint)
                .frame(width: 34, height: 34)
                .background(Color.signalMint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NotchButtonStyle())
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Показать в Finder")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(NotchButtonStyle())
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityLabel("Убрать с полки")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.signalMint.opacity(0.10), lineWidth: 0.5)
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
    }
}
