import SwiftUI

/// The global "New Task" action at the trailing end of each top bar.
struct GlobalQuickTaskButton: View {
    @Environment(DieterStore.self) private var store
    var compact = false
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            if compact {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New Task")
                }
            }
        }
        .buttonStyle(DieterBarButtonStyle(shape: compact ? .circle : .capsule, prominent: true))
        .help("New task")
        .accessibilityLabel("Quick task")
        .accessibilityIdentifier("sidebar.quick-task")
        .e2eTarget("sidebar.quick-task")
        .popover(isPresented: $presented, arrowEdge: .top) {
            QuickTaskPopover(isPresented: $presented, draft: store.quickTaskForm, chooseDestination: true)
                .environment(store)
        }
    }
}
