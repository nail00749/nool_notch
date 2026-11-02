import AppKit
import Combine
import Foundation
import OSLog

/// Advertises the paired Windows PC only while its NooL Link connection is live.
@MainActor
final class NooLAirDropCoordinator: ObservableObject {
    static let shared = NooLAirDropCoordinator()
    private static let enabledKey = "noolLink.airDropEnabled"
    /// Request paths and status codes only; file names and payloads are never logged.
    nonisolated static let log = Logger(subsystem: "com.nailuyltyev.NotchApp", category: "NooLAirDrop")

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reconcile()
        }
    }
    @Published private(set) var status = "Выключено"
    private let service = NooLLinkService.shared
    private var receiver: AirDropReceiver?
    private var advertisedName: String?
    private var timer: Timer?
    private var generation = 0
    private var consentVisible = false
    private var delivering = false
    private var retryAfter = Date.distantPast

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }

    func stop() {
        generation += 1
        receiver?.stop()
        receiver = nil
        advertisedName = nil
        status = isEnabled ? "Ожидание подключения Windows" : "Выключено"
    }

    private func reconcile() {
        let eligible = service.canReceiveFileTransfers ||
            (delivering && service.isEnabled && service.fileTransferEnabled && service.pairedDeviceName != nil)
        guard isEnabled, eligible, let name = service.pairedDeviceName,
              let identity = service.airDropIdentity else {
            if receiver != nil { stop() }
            status = isEnabled ? "Ожидание подключения Windows и разрешения передачи файлов" : "Выключено"
            return
        }
        if receiver != nil, advertisedName == name { return }
        guard Date() >= retryAfter else { return }
        stop()
        generation += 1
        let epoch = generation
        let bridge = AirDropReceiver()
        do {
            try bridge.start(identity: identity, deviceName: name, consent: { [weak self] offer in
                await self?.confirm(offer, epoch: epoch) ?? false
            }, deliver: { [weak self] urls in
                guard let self else { throw CancellationError() }
                try await self.deliver(urls, epoch: epoch)
            }, ready: { [weak self] port in
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    if port == nil {
                        self.stop()
                        self.retryAfter = Date().addingTimeInterval(15)
                        self.status = "Не удалось запустить AirDrop; повторяем подключение"
                    } else {
                        self.status = "Объявлен в AirDrop: \(name)"
                    }
                }
            }, failure: { [weak self] message in
                Self.log.error("AirDrop bridge failure: \(message, privacy: .public)")
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    self.status = message
                }
            }, activity: { event in
                Self.log.info("AirDrop \(event, privacy: .public)")
            })
            receiver = bridge
            advertisedName = name
            status = "Подготовка AirDrop…"
        } catch {
            retryAfter = Date().addingTimeInterval(15)
            status = "Не удалось запустить AirDrop: \(error.localizedDescription)"
        }
    }

    private func confirm(_ offer: AirDropOffer, epoch: Int) async -> Bool {
        guard generation == epoch, isEnabled, service.canReceiveFileTransfers,
              !consentVisible, let destination = service.pairedDeviceName else { return false }
        // Choosing the PC in this Mac's own AirDrop sheet is the consent, like
        // sending to your own devices. Only other nearby devices are asked about.
        if offer.fromThisMac { return true }
        consentVisible = true
        defer { consentVisible = false }
        let alert = NSAlert()
        alert.messageText = "Отправить файлы на \(destination)?"
        let names = offer.files.prefix(5).map(\.name).joined(separator: "\n")
        let extra = offer.files.count > 5 ? "\nи ещё \(offer.files.count - 5)" : ""
        alert.informativeText = "Запрос AirDrop от «\(offer.senderName)».\n\n\(names)\(extra)"
        alert.addButton(withTitle: "Отправить")
        alert.addButton(withTitle: "Отменить")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "NooL Link"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            let timeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
                Task { @MainActor in window.endSheet(alert.window, returnCode: .cancel) }
            }
            alert.beginSheetModal(for: window) { response in
                timeout.invalidate()
                window.orderOut(nil)
                continuation.resume(returning: response)
            }
        }
        return result == .alertFirstButtonReturn && generation == epoch && isEnabled && service.canReceiveFileTransfers
    }

    private func deliver(_ urls: [URL], epoch: Int) async throws {
        guard generation == epoch, isEnabled, service.canReceiveFileTransfers else { throw CancellationError() }
        delivering = true
        defer { delivering = false }
        try await service.sendFiles(urls)
    }
}
