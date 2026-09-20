import SwiftUI

extension View {
    func settingsHintStyle() -> some View {
        font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(NotchPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
