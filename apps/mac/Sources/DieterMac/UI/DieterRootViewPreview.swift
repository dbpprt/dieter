import SwiftUI

#Preview("Dieter") {
    DieterRootView()
        .environment(DieterStore())
        .dieterThemeRoot(
            palette: DieterPalette.defaultValue,
            appearance: DieterAppearance.defaultValue
        )
        .frame(width: 1380, height: 870)
}
