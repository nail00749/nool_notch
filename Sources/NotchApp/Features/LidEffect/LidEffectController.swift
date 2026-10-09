import AppKit
import Combine

@MainActor
protocol LidCapturePermissionProviding {
    func isAllowed() -> Bool
    func request() -> Bool
}

struct SystemLidCapturePermission: LidCapturePermissionProviding {
    func isAllowed() -> Bool { CGPreflightScreenCaptureAccess() }
    func request() -> Bool { CGRequestScreenCaptureAccess() }
}

@MainActor
final class LidEffectController: ObservableObject {
    @Published private(set) var preferences: LidEffectPreferences
    @Published private(set) var hasCapturePermission = false
    @Published private(set) var angle: Double?
    @Published private(set) var sensorStatus = "Датчик проверяется при включении эффекта."
    @Published private(set) var message: String?
    @Published private(set) var isPreviewing = false

    private let sensor: any LidAngleProviding
    private let renderer: any LidEffectRendering
    private let permission: any LidCapturePermissionProviding
    private let defaults: UserDefaults
    private let screenProvider: @MainActor () -> NSScreen?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var lastReading: ContinuousClock.Instant?
    private var sensorSearchStartedAt: ContinuousClock.Instant?
    private var previewValue: Double?
    private var captureActive = false
    private var activeCaptureGeneration: UUID?
    private var renderFailed = false
    private var captureGeneration = UUID()
    private var sensorGeneration = UUID()
    private var started = false
    private var stopped = false
    private var suspended = false
    private var locked = false
    private static let preferencesKey = "nool.lidEffect.preferences.v1"

    init(defaults: UserDefaults = .standard,
         sensor: any LidAngleProviding = SystemLidAngleSensor(),
         renderer: any LidEffectRendering = ScreenLidEffectRenderer(),
         permission: any LidCapturePermissionProviding = SystemLidCapturePermission(),
         screenProvider: @escaping @MainActor () -> NSScreen? = LidEffectController.builtInScreen) {
        self.defaults = defaults
        self.sensor = sensor
        self.renderer = renderer
        self.permission = permission
        self.screenProvider = screenProvider
        preferences = defaults.data(forKey: Self.preferencesKey).flatMap {
            try? JSONDecoder().decode(LidEffectPreferences.self, from: $0)
        }?.sanitized ?? LidEffectPreferences()
        renderer.onFailure = { [weak self] message in self?.renderFailure(message) }
    }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        suspended = false
        locked = false
        refreshPermission()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resume() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.invalidateCapture()
                self.cancelPreview()
                self.restartSensor()
            }
        })
        // Additional cleanup signals; sleep/session and renderer frame expiry remain independent guards.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.locked = locked
                    if locked { self.suspend() } else { self.resume() }
                }
            })
        }
        restartSensor()
        configureMonitor()
    }

    private func configureMonitor() {
        guard started, !stopped, !suspended, preferences.enabled || isPreviewing else {
            monitor?.cancel()
            monitor = nil
            return
        }
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.checkFreshness()
            }
        }
    }

    func setPreferences(_ value: LidEffectPreferences) {
        guard !stopped else { return }
        let wasEnabled = preferences.enabled
        preferences = value.sanitized
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.preferencesKey) }
        if wasEnabled != preferences.enabled {
            message = nil
            renderFailed = false
            cancelPreview()
            refreshPermission()
            restartSensor()
        }
        configureMonitor()
        scheduleRender()
    }

    func refreshPermission() {
        guard !stopped else { return }
        hasCapturePermission = permission.isAllowed()
        if !hasCapturePermission { invalidateCapture() }
    }

    func requestCapturePermission() {
        guard !stopped else { return }
        _ = permission.request()
        refreshPermission()
        message = hasCapturePermission ? nil : "Разрешите запись экрана для NooL App в настройках macOS. После выдачи доступа может потребоваться перезапуск NooL App."
        renderFailed = false
        scheduleRender()
    }

    func preview() {
        guard started, !stopped, !suspended, !locked, !isPreviewing else { return }
        refreshPermission()
        guard hasCapturePermission else { message = "Для предпросмотра разрешите запись экрана кнопкой ниже."; return }
        guard screenProvider() != nil else { message = "Предпросмотр доступен на встроенном экране MacBook."; return }
        renderFailed = false
        message = nil
        isPreviewing = true
        configureMonitor()
        previewValue = 0
        previewTask = Task { @MainActor [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let duration = start.duration(to: .now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                guard elapsed < 3 else { break }
                self?.previewValue = LidEffectPolicy.previewProgress(elapsed: elapsed)
                self?.scheduleRender()
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
            self?.previewValue = nil
            self?.isPreviewing = false
            self?.previewTask = nil
            self?.configureMonitor()
            self?.scheduleRender()
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewValue = nil
        isPreviewing = false
        configureMonitor()
        scheduleRender()
    }

    func suspend() {
        suspended = true
        sensorSearchStartedAt = nil
        sensorGeneration = UUID()
        sensor.stop()
        angle = nil
        lastReading = nil
        invalidateCapture()
        cancelPreview()
    }

    func resume() {
        guard started, !stopped, !locked else { return }
        suspended = false
        renderFailed = false
        refreshPermission()
        restartSensor()
        configureMonitor()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pause()
    }

    /// Unloads the effect while preserving preferences and allowing a later start.
    func pause() {
        started = false
        suspend()
        monitor?.cancel()
        monitor = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        distributedObservers.removeAll()
    }

    func waitForStop() async { await renderTask?.value }

    private func restartSensor() {
        sensorSearchStartedAt = nil
        sensorGeneration = UUID()
        sensor.stop()
        angle = nil
        lastReading = nil
        guard started, !stopped, !suspended, !locked, preferences.enabled else {
            sensorStatus = "Эффект выключен."
            scheduleRender()
            return
        }
        guard screenProvider() != nil else {
            sensorStatus = "Встроенный экран MacBook не найден."
            scheduleRender()
            return
        }
        sensorStatus = "Ищем датчик угла крышки…"
        sensorSearchStartedAt = .now
        let generation = sensorGeneration
        sensor.start { [weak self] reading in
            guard let self, self.sensorGeneration == generation, !self.stopped, !self.suspended else { return }
            switch reading {
            case .angle(let angle):
                guard angle.isFinite, (0...180).contains(angle) else { return }
                self.sensorSearchStartedAt = nil
                self.angle = angle
                self.lastReading = .now
                self.sensorStatus = "Датчик доступен · \(Int(angle.rounded()))°"
            case .unavailable(let reason):
                self.sensorSearchStartedAt = nil
                self.angle = nil
                self.lastReading = nil
                self.sensorStatus = reason
                self.invalidateCapture()
            }
            self.scheduleRender()
        }
    }

    private func checkFreshness() {
        guard !stopped else { return }
        if let sensorSearchStartedAt, sensorSearchStartedAt.duration(to: .now) > .seconds(2) {
            self.sensorSearchStartedAt = nil
            sensorGeneration = UUID()
            sensor.stop()
            sensorStatus = "Датчик не ответил. Выключите и включите эффект для повтора."
            invalidateCapture()
        }
        if let lastReading, lastReading.duration(to: .now) > .seconds(1) {
            angle = nil
            self.lastReading = nil
            sensorStatus = "Нет свежих данных датчика. Эффект скрыт."
            scheduleRender()
        }
        if captureActive, !permission.isAllowed() {
            hasCapturePermission = false
            invalidateCapture()
        }
    }

    private var targetProgress: Double {
        guard started, !stopped, !suspended, !locked, hasCapturePermission, !renderFailed else { return 0 }
        if let previewValue { return previewValue }
        guard preferences.enabled, let lastReading, lastReading.duration(to: .now) <= .seconds(1) else { return 0 }
        return LidEffectPolicy.progress(angle: angle, startAngle: preferences.startAngle)
    }

    private func invalidateCapture() {
        captureGeneration = UUID()
        renderer.update(progress: 0, blurRadius: 0, dimming: 0)
        scheduleRender()
    }

    private func renderFailure(_ reason: String) {
        renderFailed = true
        message = reason
        invalidateCapture()
        cancelPreview()
    }

    private func scheduleRender() {
        if targetProgress == 0 { renderer.update(progress: 0, blurRadius: 0, dimming: 0) }
        guard renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.renderTask = nil }
            while true {
                if self.captureActive, self.activeCaptureGeneration != self.captureGeneration {
                    await self.renderer.stop()
                    self.captureActive = false
                    self.activeCaptureGeneration = nil
                    continue
                }
                if self.targetProgress == 0 {
                    if self.captureActive {
                        await self.renderer.stop()
                        self.captureActive = false
                        self.activeCaptureGeneration = nil
                        continue
                    }
                    return
                }
                if !self.captureActive {
                    guard let screen = self.screenProvider() else { return }
                    let generation = self.captureGeneration
                    do {
                        try await self.renderer.start(screen: screen)
                        self.captureActive = true
                        self.activeCaptureGeneration = generation
                    } catch {
                        await self.renderer.stop()
                        if generation == self.captureGeneration {
                            self.renderFailed = true
                            self.message = "Не удалось запустить размытие экрана. Проверьте разрешение и повторите включение."
                        }
                        return
                    }
                    if generation != self.captureGeneration {
                        await self.renderer.stop()
                        self.captureActive = false
                        self.activeCaptureGeneration = nil
                        continue
                    }
                    continue
                }
                self.renderer.update(progress: self.targetProgress, blurRadius: self.preferences.blurRadius,
                                     dimming: self.preferences.dimming)
                return
            }
        }
    }

    deinit {
        monitor?.cancel()
        previewTask?.cancel()
        renderTask?.cancel()
    }
}
