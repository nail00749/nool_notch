import SwiftUI

struct DisplayArrangementView: View {
    let displays: [DisplayInfo]
    let isPending: Bool
    let onApply: ([DisplayPlacement]) -> Void
    let onClose: () -> Void
    @State private var draft: [String: CGRect] = [:]
    @State private var selectedID = ""
    @State private var draggedID: String?
    @State private var dragTranslation = CGSize.zero
    @State private var hint: String?

    private var eligible: [DisplayInfo] {
        displays.filter { $0.isEnabled && $0.mirrorMasterID == nil && $0.frame.width > 0 && $0.frame.height > 0 }
    }
    private var mainID: String { eligible.first(where: \.isMain)?.id ?? eligible.first?.id ?? "" }
    private var liveFrames: [String: CGRect] {
        DisplayArrangementGeometry.normalized(Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0.frame) }), mainID: mainID)
    }
    private var canApply: Bool { draft != liveFrames && DisplayArrangementGeometry.isValid(draft) && !isPending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).accessibilityLabel("Назад к дисплеям")
                Text("Расположение").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: reset) { Label("Сбросить", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(ArrangementActionStyle())
                    .disabled(draft == liveFrames)
            }

            canvas.frame(height: 124)
                .background(.black, in: RoundedRectangle(cornerRadius: 11))
                .clipShape(RoundedRectangle(cornerRadius: 11))
            if eligible.count > 1 {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(eligible) { display in
                            Button(display.name) { selectedID = display.id }
                        }
                    } label: {
                        DisplayMenuField(title: "Дисплей", value: selectedName, icon: "display", compact: true)
                    }
                    .displayMenuStyle().frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Text(hint ?? (displays.contains(where: { $0.isEnabled && $0.mirrorMasterID != nil })
                     ? "Зеркальные экраны следуют за основным."
                     : "Перетащите экран. Центры и края притягиваются."))
                    .font(.system(size: 9)).foregroundStyle(DisplayControlTheme.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("Отмена", action: onClose).buttonStyle(ArrangementActionStyle())
                    Button("Применить") {
                        guard canApply else { return }
                        onApply(eligible.compactMap { display in
                            draft[display.id].map { DisplayPlacement(uuid: display.id, origin: $0.origin) }
                        })
                    }
                    .buttonStyle(ArrangementActionStyle(prominent: true)).disabled(!canApply)
                }
                .fixedSize()
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 17))
        .disabled(isPending)
        .onAppear(perform: reset)
        .onChange(of: displays) { _, _ in
            reset()
            hint = "Состав или параметры дисплеев изменились. Черновик сброшен."
        }
        .onChange(of: isPending) { _, pending in if pending { reset() } }
    }

    private var selectedName: String { eligible.first { $0.id == selectedID }?.name ?? "дисплей" }

    private var canvas: some View {
        GeometryReader { proxy in
            let outlines = DisplayArrangementGeometry.previewFrames(draft, displays: eligible, mainID: mainID)
            let bounds = draft.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1)
                : outlines.values.reduce(CGRect.null) { $0.union($1) }
            let scale = max(0.001, min((proxy.size.width - 30) / max(bounds.width, 1),
                                      (proxy.size.height - 30) / max(bounds.height, 1)))
            let offset = CGPoint(x: (proxy.size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                                 y: (proxy.size.height - bounds.height * scale) / 2 - bounds.minY * scale)
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Нет доступных экранов для размещения")
                        .font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                ForEach(eligible) { display in
                    if let frame = outlines[display.id] {
                        tile(display, size: CGSize(width: frame.width * scale, height: frame.height * scale))
                            .position(x: frame.midX * scale + offset.x + (draggedID == display.id ? dragTranslation.width : 0),
                                      y: frame.midY * scale + offset.y + (draggedID == display.id ? dragTranslation.height : 0))
                            .zIndex(draggedID == display.id ? 1 : 0)
                            .onTapGesture { selectedID = display.id }
                            .gesture(DragGesture(minimumDistance: 3)
                                .onChanged { event in
                                    selectedID = display.id
                                    draggedID = display.id
                                    let origin = DisplayArrangementGeometry.magnetizedOrigin(display.id,
                                        proposedOrigin: CGPoint(x: frame.minX + event.translation.width / scale,
                                                                y: frame.minY + event.translation.height / scale),
                                        frames: outlines, tolerance: 8 / scale)
                                    dragTranslation = CGSize(width: (origin.x - frame.minX) * scale,
                                                             height: (origin.y - frame.minY) * scale)
                                }
                                .onEnded { event in
                                    let previewOrigin = DisplayArrangementGeometry.magnetizedOrigin(display.id,
                                        proposedOrigin: CGPoint(x: frame.minX + event.translation.width / scale,
                                                                y: frame.minY + event.translation.height / scale),
                                        frames: outlines, tolerance: 8 / scale)
                                    if let origin = DisplayArrangementGeometry.desktopOrigin(display.id, previewOrigin: previewOrigin,
                                                                                            frames: draft, outlines: outlines) {
                                        draft = DisplayArrangementGeometry.snapped(display.id, proposedOrigin: origin,
                                                                                  frames: draft, mainID: mainID)
                                    }
                                    draggedID = nil
                                    dragTranslation = .zero
                                    hint = nil
                                })
                    }
                }
            }
        }
    }

    private func tile(_ display: DisplayInfo, size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 7)
        .fill(selectedID == display.id ? Color.white : Color(white: 0.24))
        .frame(width: size.width, height: size.height)
        .overlay {
            VStack(spacing: 3) {
                Text(display.name).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                if display.isMain { Text("Главный").font(.system(size: 7)).lineLimit(1) }
            }
            .foregroundStyle(selectedID == display.id ? .black : .white)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if display.isMain {
                Capsule().fill(selectedID == display.id ? .black.opacity(0.7) : .white.opacity(0.85))
                    .frame(height: 2).padding(.horizontal, 6).padding(.top, 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(selectedID == display.id ? 1 : 0.28), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.name + (display.isMain ? ", главный дисплей" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(selectedID == display.id ? "Выбран" : "")
        .accessibilityAction { selectedID = display.id }
    }

    private func reset() {
        draft = liveFrames
        selectedID = eligible.contains(where: { $0.id == selectedID }) ? selectedID : eligible.first?.id ?? ""
        draggedID = nil
        dragTranslation = .zero
        hint = nil
    }

}

private struct ArrangementActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 28)
            .background(prominent ? Color.white : Color.white.opacity(configuration.isPressed ? 0.15 : 0.07),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}
