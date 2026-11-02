import Foundation

/// The fixed-width Launcher fits five application tiles. Other results span a row.
enum LauncherResultLayout {
    static let columns = 5

    static func rows(_ results: [LauncherResult]) -> [[LauncherResult]] {
        var rows: [[LauncherResult]] = []
        for result in results {
            if case .application = result.payload,
               let last = rows.last, last.count < columns,
               let first = last.first, case .application = first.payload {
                rows[rows.count - 1].append(result)
            } else {
                rows.append([result])
            }
        }
        return rows
    }

    static func verticalSelection(current: String?, offset: Int, results: [LauncherResult]) -> String? {
        let rows = rows(results)
        guard let row = rows.firstIndex(where: { $0.contains { $0.id == current } }),
              let column = rows[row].firstIndex(where: { $0.id == current }) else { return results.first?.id }
        let target = min(max(row + offset, 0), rows.count - 1)
        if target == row { return current }
        return rows[target][min(column, rows[target].count - 1)].id
    }

    static func horizontalSelection(current: String?, offset: Int, results: [LauncherResult]) -> String? {
        guard let row = rows(results).first(where: { $0.contains { $0.id == current } }),
              let column = row.firstIndex(where: { $0.id == current }) else { return results.first?.id }
        return row[min(max(column + offset, 0), row.count - 1)].id
    }
}
