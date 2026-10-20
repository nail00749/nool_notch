import AppKit
import Combine
import SwiftUI

/// Owns the confirmation window independently of the notch's hover lifecycle.
@MainActor
final class DisplayRevertController: ObservableObject {
    @Published private(set) var secondsRemaining = 15
    @Published private(set) var isPresented = false
    private var timer: Task<Void, Never>?
    private var panel: NSPanel?
    private var deadline: ContinuousClock.Instant?
    private var onConfirm: (() -> Void)?
    private var onRevert: (() -> Void)?
    private var displayID: UInt32?
    private let showsWindow: Bool
    private let timeout: Duration

    init(showsWindow: Bool = true, timeout: Duration = .seconds(15)) {
        self.showsWindow = showsWindow
        self.timeout = timeout
    }

    func present(displayID: UInt32, confirm: @escaping () -> Void, revert: @escaping () -> Void) {
        dismiss()
        self.displayID = displayID
        onConfirm = confirm
        onRevert = revert
        secondsRemaining = 15
        deadline = .now.advanced(by: timeout)
        isPresented = true
        if showsWindow {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 180),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Настройки дисплея"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: DisplayRevertView(controller: self))
            panel = window
            reposition()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let deadline = self.deadline else { return }
                let duration = ContinuousClock.now.duration(to: deadline)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                self.secondsRemaining = max(0, Int(ceil(seconds)))
                if seconds <= 0 { self.revert(); return }
            }
        }
    }

    func reposition() {
        guard let panel, let displayID,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
              }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width / 2,
                                     y: screen.frame.midY - panel.frame.height / 2))
    }

    func confirm() {
        let action = onConfirm
        dismiss()
        action?()
    }

    func revert() {
        let action = onRevert
        dismiss()
        action?()
    }

    func dismiss() {
        timer?.cancel()
        timer = nil
        deadline = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        onConfirm = nil
        onRevert = nil
        displayID = nil
        isPresented = false
    }
}

private struct DisplayRevertView: View {
    @ObservedObject var controller: DisplayRevertController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Оставить настройки дисплея?").font(.system(size: 16, weight: .semibold))
            Text("Прежние настройки вернутся через \(controller.secondsRemaining) с.")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(DisplayControlTheme.secondary)
            HStack {
                Spacer()
                Button("Вернуть", action: controller.revert).keyboardShortcut(.cancelAction)
                    .buttonStyle(DisplayActionStyle())
                Button("Оставить", action: controller.confirm).keyboardShortcut(.defaultAction)
                    .buttonStyle(DisplayActionStyle(prominent: true))
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 370, height: 180)
        .background(.black).foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
