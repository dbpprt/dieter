import SwiftUI

/// Keep the navigator and editor in one SwiftUI host. The native HSplitView
/// can detach its navigator host when an active NSTextView is replaced by an
/// error/placeholder. A stable split also preserves the user's chosen width.
struct FilePaneSplit<Navigator: View, Preview: View>: View {
    @ViewBuilder let navigator: Navigator
    @ViewBuilder let preview: Preview
    @AppStorage("DieterFilesPaneWidth") private var storedWidth = 340.0
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(260, min(440, geometry.size.width - 327))
            let width = min(max(storedWidth, 260), maximum)
            HStack(spacing: 0) {
                navigator.frame(width: width, height: geometry.size.height)
                Rectangle().fill(DieterTheme.border)
                    .frame(width: 1)
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = width }
                            storedWidth = min(max((dragStart ?? width) + value.translation.width, 260), maximum)
                        }
                        .onEnded { _ in dragStart = nil })
                    .accessibilityLabel("File navigator width")
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: storedWidth = min(width + 20, maximum)
                        case .decrement: storedWidth = max(width - 20, 260)
                        @unknown default: break
                        }
                    }
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
