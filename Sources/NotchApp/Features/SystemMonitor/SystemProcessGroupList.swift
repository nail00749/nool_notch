import AppKit
import SwiftUI

/// Flat, reusable process groups for the Dock summary and the standalone window.
struct SystemProcessGroupList: View {
    let groups: [SystemProcessGroup]
    let sort: SystemProcessSort
    var compact = true
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if !compact { columnHeadings }
            ForEach(groups) { group in
                groupRow(group)
                if expandedGroups.contains(group.id) {
                    ForEach(group.processes) { process in processRow(process) }
                }
                if !compact, group.id != groups.last?.id {
                    Divider().padding(.leading, 42)
                }
            }
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 8) {
            Text("Приложение")
            Spacer(minLength: 8)
            Text("ЦП").frame(width: 60, alignment: .trailing)
            Text("ОЗУ · RSS").frame(width: 82, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(NotchPalette.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func groupRow(_ group: SystemProcessGroup) -> some View {
        Button {
            if expandedGroups.contains(group.id) { expandedGroups.remove(group.id) }
            else { expandedGroups.insert(group.id) }
        } label: {
            HStack(spacing: 9) {
                appIcon(group)
                if compact {
                    Text(SystemProcessGroupDisplayNameCache.displayName(for: group))
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    if group.processes.count > 1 {
                        Text("· \(group.processes.count)")
                            .font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
                            .fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SystemProcessGroupDisplayNameCache.displayName(for: group))
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(group.processes.count) процессов")
                            .font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
                    }
                }
                Spacer(minLength: 5)
                if compact {
                    compactMetric(cpuPercent: group.cpuPercent, memoryBytes: group.residentMemoryBytes)
                        .frame(width: 72, alignment: .trailing)
                } else {
                    metricText(group.cpuPercent, suffix: "%")
                        .frame(width: 60, alignment: .trailing)
                    Text(SystemMetricReading.bytes(group.residentMemoryBytes))
                        .frame(width: 82, alignment: .trailing)
                }
                Image(systemName: expandedGroups.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondary)
            }
            .font(.system(size: compact ? 10 : 11))
            .monospacedDigit()
            .padding(.horizontal, compact ? 6 : 12)
            .frame(height: compact ? 24 : 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Показать процессы группы «\(SystemProcessGroupDisplayNameCache.displayName(for: group))»")
    }

    @ViewBuilder
    private func appIcon(_ group: SystemProcessGroup) -> some View {
        if let path = group.applicationPath, !path.isEmpty {
            Image(nsImage: SystemProcessGroupDisplayNameCache.icon(for: path))
                .resizable().interpolation(.high).frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(NotchPalette.secondary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }

    private func processRow(_ process: MonitoredSystemProcess) -> some View {
        HStack(spacing: 8) {
            Text("PID \(process.pid) · \(process.name)")
                .lineLimit(1).foregroundStyle(NotchPalette.secondary)
            Spacer(minLength: 5)
            if compact {
                compactMetric(cpuPercent: process.cpuPercent, memoryBytes: process.residentMemoryBytes)
                    .frame(width: 72, alignment: .trailing)
            } else {
                metricText(process.cpuPercent, suffix: "%")
                    .frame(width: 60, alignment: .trailing)
                Text(SystemMetricReading.bytes(process.residentMemoryBytes))
                    .frame(width: 82, alignment: .trailing)
            }
        }
        .font(.system(size: 9)).monospacedDigit()
        .padding(.leading, compact ? 21 : 42).padding(.trailing, compact ? 6 : 12)
        .frame(height: 28)
    }

    @ViewBuilder
    private func compactMetric(cpuPercent: Double?, memoryBytes: UInt64) -> some View {
        if sort == .cpu {
            metricText(cpuPercent, suffix: "%")
        } else {
            Text(SystemMetricReading.bytes(memoryBytes))
        }
    }

    @ViewBuilder
    private func metricText(_ value: Double?, suffix: String = "") -> some View {
        if let value, value.isFinite {
            Text(value.formatted(.number.precision(.fractionLength(1))) + suffix)
        } else {
            Text("—").foregroundStyle(NotchPalette.secondary)
        }
    }
}

@MainActor
private enum SystemProcessGroupDisplayNameCache {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 64
        return cache
    }()
    private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = icons.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        let cost = max(1, Int(icon.size.width * icon.size.height * 4))
        icons.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    static func displayName(for group: SystemProcessGroup) -> String {
        guard let path = group.applicationPath, !path.isEmpty else { return group.name }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? group.name
        cache.setObject(displayName as NSString, forKey: key)
        return displayName
    }
}
