import AppKit
import Darwin
import WebKit

/// A local, disposable web process for the bundled scene renderer. Project files never
/// become file:// URLs, and imported scripts are disabled by the bundled host.
@MainActor
final class WallpaperEngineWebView: NSView, WKNavigationDelegate, WKUIDelegate {
    let projectURL: URL
    private(set) var isReady = false
    private(set) var reportedFrameCount: UInt64 = 0
    private(set) var cachedSnapshot: CGImage?
    private(set) var snapshotRevision = 0
    var onFailure: ((String) -> Void)?
    var onReady: (() -> Void)?

    private var webView: WKWebView!
    private var schemeHandler: WallpaperEngineSchemeHandler!
    private let messageProxy = WallpaperEngineMessageProxy()
    private var cursorTimer: Timer?
    private var settings: [String: Any] = ["playing": false, "framesPerSecond": 60,
                                         "volume": 0, "playbackRate": 1, "scaleMode": "fill"]
    private var screenFrame = CGRect.zero
    private var previousCursor: CGPoint?
    private var cursorWasOutside = false
    private var stopped = false
    private var snapshotInFlight = false
    private var notifiedReady = false

    init?(projectURL: URL) {
        self.projectURL = projectURL
        super.init(frame: .zero)
        guard let handler = WallpaperEngineSchemeHandler(projectURL: projectURL) else { return nil }
        schemeHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "noolwe")
        configuration.userContentController.add(messageProxy, name: "noolWallpaper")
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        messageProxy.owner = self
        // Install the network rule before loading any content; a compilation error fails closed.
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^noolwe:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nool-wallpaper-local-v1",
                                                                encodedContentRuleList: rules) { [weak self] list, _ in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                guard let list else { self.fail(); return }
                self.webView.configuration.userContentController.add(list)
                self.webView.load(URLRequest(url: URL(string: "noolwe://runtime/index.html")!))
            }
        }
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(playing: Bool, framesPerSecond: Int, volume: Double, playbackRate: Double,
               scaleMode: LiveWallpaperScaleMode, screenFrame: CGRect) {
        guard !stopped else { return }
        self.screenFrame = screenFrame
        let wasPlaying = settings["playing"] as? Bool == true
        let nextSettings: [String: Any] = ["playing": playing, "framesPerSecond": min(120, max(1, framesPerSecond)),
                    "volume": volume.isFinite ? min(1, max(0, volume)) : 0,
                    "playbackRate": playbackRate.isFinite ? min(4, max(0.25, playbackRate)) : 1,
                    "scaleMode": scaleMode.rawValue,
                    "width": max(1, bounds.width), "height": max(1, bounds.height)]
        let changed = !NSDictionary(dictionary: settings).isEqual(to: nextSettings)
        settings = nextSettings
        if changed { send(settings) }
        updateCursorTimer(playing: playing && isReady)
        if !playing, isReady, wasPlaying || cachedSnapshot == nil { requestSnapshot() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        cursorTimer?.invalidate()
        cursorTimer = nil
        webView.evaluateJavaScript("window.noolWallpaper?.stop()", completionHandler: nil)
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "noolWallpaper")
        schemeHandler.cancelAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onReady = nil
        onFailure = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, isReady { requestSnapshot() }
    }

    private func send(_ value: [String: Any]) {
        guard isReady, !stopped else { return }
        webView.callAsyncJavaScript("window.noolWallpaper.apply(settings)", arguments: ["settings": value],
                                   in: nil, in: .page, completionHandler: nil)
    }

    /// Read-only diagnostics for the native renderer acceptance checks.
    func readDiagnosticState(_ completion: @escaping (String?) -> Void) {
        guard !stopped else { completion(nil); return }
        webView.evaluateJavaScript("JSON.stringify(window.noolWallpaper.getState())") { value, _ in
            completion(value as? String)
        }
    }

    private func updateCursorTimer(playing: Bool) {
        guard playing else {
            cursorTimer?.invalidate()
            cursorTimer = nil
            return
        }
        guard cursorTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCursor() }
        }
        timer.tolerance = 0.008
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func updateCursor() {
        let cursor = NSEvent.mouseLocation
        guard screenFrame.width > 0, screenFrame.height > 0, screenFrame.contains(cursor) else {
            if !cursorWasOutside { send(["cursor": NSNull()]); cursorWasOutside = true; previousCursor = nil }
            return
        }
        let point = CGPoint(x: (cursor.x - screenFrame.minX) / screenFrame.width,
                            y: 1 - (cursor.y - screenFrame.minY) / screenFrame.height)
        guard cursorWasOutside || previousCursor != point else { return }
        cursorWasOutside = false
        previousCursor = point
        send(["cursor": ["x": point.x, "y": point.y]])
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "noolwe",
              message.frameInfo.request.url?.host == "runtime",
              let body = message.body as? [String: Any], body.count <= 3,
              let status = body["status"] as? String else { return }
        switch status {
        case "ready":
            guard !isReady else { return }
            isReady = true
            send(settings) // Applies a pause requested before the asynchronous mount finished.
            updateCursorTimer(playing: settings["playing"] as? Bool == true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                self?.requestSnapshot()
            }
        case "frame":
            if let count = body["frame"] as? NSNumber, count.doubleValue.isFinite,
               count.doubleValue >= 0, count.doubleValue < Double(UInt64.max) {
                reportedFrameCount = max(reportedFrameCount, count.uint64Value)
            }
        case "failure": fail()
        default: break
        }
    }

    /// Captures on demand; unchanged paused configurations do not keep rendering snapshots.
    func requestSnapshot() {
        guard !stopped, isReady, window != nil, bounds.width > 0, bounds.height > 0,
              !snapshotInFlight else { return }
        snapshotInFlight = true
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotInFlight = false
            guard !self.stopped, let image, let cgImage = image.cgImage(forProposedRect: nil,
                                                                       context: nil, hints: nil) else { return }
            self.cachedSnapshot = cgImage
            self.snapshotRevision += 1
            if !self.notifiedReady { self.notifiedReady = true; self.onReady?() }
        }
    }

    private func fail() {
        guard !stopped else { return }
        let callback = onFailure
        stop()
        callback?("Не удалось воспроизвести сцену Wallpaper Engine.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(!stopped && navigationAction.targetFrame?.isMainFrame == true &&
                        url?.absoluteString == "noolwe://runtime/index.html" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
}

@MainActor
private final class WallpaperEngineMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WallpaperEngineWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor
private final class WallpaperEngineSchemeHandler: NSObject, WKURLSchemeHandler {
    private let files: [String: URL]
    private var tasks: [ObjectIdentifier: (task: any WKURLSchemeTask, read: WallpaperEngineFileRead)] = [:]
    private let ioQueue = DispatchQueue(label: "nool.wallpaper-engine.files", qos: .userInitiated)

    init?(projectURL: URL) {
        let root = projectURL.resolvingSymlinksInPath().standardizedFileURL
        var files: [String: URL] = [:]
        for filename in ["index.html", "host.js", "uniform-cache.js", "webwallgl.global.min.js", "style.css"] {
            let parts = filename.split(separator: ".")
            let ext = String(parts.last!)
            let name = filename.dropLast(ext.count + 1)
            if let url = Bundle.module.url(forResource: String(name), withExtension: ext, subdirectory: "WallpaperEngine")
                ?? Bundle.module.url(forResource: String(name), withExtension: ext) {
                files["noolwe://runtime/" + filename] = url
            }
        }
        guard files["noolwe://runtime/index.html"] != nil,
              files["noolwe://runtime/host.js"] != nil,
              files["noolwe://runtime/webwallgl.global.min.js"] != nil else { return nil }
        for name in ["scene.pkg", "project.json", "preview.jpg", "preview.png"] {
            let url = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
            guard url.deletingLastPathComponent() == root,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize,
                  size <= (name == "scene.pkg" ? 512 * 1_024 * 1_024 : 16 * 1_024 * 1_024) else { continue }
            files["noolwe://runtime/project/" + name] = url
        }
        guard files["noolwe://runtime/project/scene.pkg"] != nil else { return nil }
        self.files = files
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET",
              let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        guard let file = files[url.absoluteString] else {
            if url.absoluteString == "noolwe://runtime/project/project.json" {
                urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            }
            return
        }
        let read = WallpaperEngineFileRead()
        tasks[key] = (urlSchemeTask, read)
        ioQueue.async { [weak self] in
            let data = read.load(file, maximumBytes: file.lastPathComponent == "scene.pkg"
                                 ? 512 * 1_024 * 1_024 : 16 * 1_024 * 1_024)
            Task { @MainActor [weak self] in
                guard let self, let entry = self.tasks.removeValue(forKey: key) else { return }
                let task = entry.task
                guard let data else { task.didFailWithError(URLError(.cannotOpenFile)); return }
                let type: String
                switch file.pathExtension.lowercased() {
                case "html": type = "text/html"
                case "js": type = "application/javascript"
                case "css": type = "text/css"
                case "json": type = "application/json"
                case "png": type = "image/png"
                case "jpg": type = "image/jpeg"
                default: type = "application/octet-stream"
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": type, "Content-Length": String(data.count),
                                   "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.read.cancel()
    }
    func cancelAll() {
        for entry in tasks.values { entry.read.cancel() }
        tasks.removeAll()
    }
}

/// The file descriptor rejects symlinks at the time of opening, and the size is
/// rechecked on that descriptor. Stop/cancellation also prevents a queued large read.
private final class WallpaperEngineFileRead: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func load(_ url: URL, maximumBytes: Int) -> Data? {
        guard !isCancelled else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= maximumBytes else { return nil }
        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while !isCancelled {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else { return nil }
            result.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}
