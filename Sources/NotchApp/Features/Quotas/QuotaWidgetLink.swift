import Foundation

enum QuotaWidgetLink {
    static func opensLimits(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "nool-notch"
            && url.host?.lowercased() == "limits"
            && (url.path.isEmpty || url.path == "/")
            && url.query == nil && url.fragment == nil
            && url.user == nil && url.password == nil && url.port == nil
    }
}
