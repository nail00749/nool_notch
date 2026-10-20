import SwiftUI

struct DisplayPresetManagerView: View {
    @ObservedObject var model: DisplayFeatureModel
    @State private var draftName = ""
    @State private var editingID: UUID?
    @State private var renameName = ""
    @State private var isSaving = false
    @FocusState private var nameIsFocused: Bool

    private var isBusy: Bool { isSaving || model.isApplyingPreset || model.isPending }
    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { model.isManagingPresets = false } label: {
                    Image(systemName: "chevron.left").frame(width: 26, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel("Назад к дисплеям")
                Text("Пресеты дисплеев").font(.system(size: 12, weight: .semibold))
                Spacer()
                if isSaving || model.isApplyingPreset {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(isSaving ? "Сохранение пресета" : "Применение пресета")
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Сохранить текущую конфигурацию").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DisplayControlTheme.secondary)
                HStack(spacing: 8) {
                    TextField("Название пресета", text: $draftName)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 11).frame(height: 40)
                        .background(DisplayControlTheme.field, in: RoundedRectangle(cornerRadius: 10))
                        .focused($nameIsFocused).onSubmit(save)
                        .onChange(of: draftName) { _, value in
                            if value.count > 80 { draftName = String(value.prefix(80)) }
                        }
                    Button(action: save) { Image(systemName: "plus").frame(width: 16) }
                        .buttonStyle(DisplayActionStyle(prominent: true))
                        .accessibilityLabel("Сохранить текущую конфигурацию")
                        .disabled(trimmedName.isEmpty || model.displays.isEmpty)
                }
                Text("Экраны, расположение, режимы, яркость и цветовые профили.")
                    .font(.system(size: 9)).foregroundStyle(DisplayControlTheme.secondary)
            }

            if model.presets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack").font(.system(size: 24, weight: .light))
                    Text("Сохранённых пресетов пока нет").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DisplayControlTheme.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.presets) { preset in
                        presetRow(preset)
                        if preset.id != model.presets.last?.id {
                            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                                .padding(.horizontal, 10)
                        }
                    }
                }
                .background(DisplayControlTheme.field.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(12)
        .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 18))
        .disabled(isBusy)
        .onChange(of: model.presets.map(\.id)) { _, ids in
            if let editingID, !ids.contains(editingID) { self.editingID = nil }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: DisplayPreset) -> some View {
        if editingID == preset.id {
            HStack(spacing: 7) {
                TextField("Название пресета", text: $renameName)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { rename(preset.id) }
                    .onChange(of: renameName) { _, value in
                        if value.count > 80 { renameName = String(value.prefix(80)) }
                    }
                Button { editingID = nil } label: {
                    Image(systemName: "xmark").frame(width: 25, height: 32)
                }
                .buttonStyle(.plain).accessibilityLabel("Отменить переименование")
                Button { rename(preset.id) } label: {
                    Image(systemName: "checkmark").frame(width: 25, height: 32)
                }
                .buttonStyle(.plain).accessibilityLabel("Сохранить название")
                .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .help(preset.name)
                    Text("Экранов: \(preset.displays.count)")
                        .font(.system(size: 9)).foregroundStyle(DisplayControlTheme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Применить") {
                    guard !isBusy else { return }
                    Task { await model.applyPreset(id: preset.id) }
                }
                .buttonStyle(DisplayActionStyle())
                Menu {
                    Button {
                        renameName = preset.name
                        editingID = preset.id
                    } label: { Label("Переименовать", systemImage: "pencil") }
                    Button(role: .destructive) { model.deletePreset(id: preset.id) } label: {
                        Label("Удалить пресет", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                }
                .displayMenuStyle().accessibilityLabel("Действия с пресетом \(preset.name)")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private func save() {
        guard !isBusy, !trimmedName.isEmpty, !model.displays.isEmpty else { return }
        let name = trimmedName
        let previousIDs = Set(model.presets.map(\.id))
        isSaving = true
        nameIsFocused = false
        Task {
            await model.savePreset(named: name)
            if model.presets.contains(where: { !previousIDs.contains($0.id) }) { draftName = "" }
            isSaving = false
        }
    }

    private func rename(_ id: UUID) {
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !name.isEmpty else { return }
        model.renamePreset(id: id, to: name)
        if model.presets.first(where: { $0.id == id })?.name == name { editingID = nil }
    }
}
