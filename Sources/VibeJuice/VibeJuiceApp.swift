import SwiftUI

@main
struct VibeJuiceApp: App {
    @StateObject private var store = Store()

    init() {
        // Menu bar only, no Dock icon, also when run via `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // VIBEJUICE_DEBUG_WINDOW=1 also shows the popover as a plain window (screenshots, dev).
        Window("VibeJuice", id: "debug") {
            PopoverView().environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(debugWindow ? .presented : .suppressed)
    }

    private let debugWindow = ProcessInfo.processInfo.environment["VIBEJUICE_DEBUG_WINDOW"] != nil
}

/// Shows a dot per provider: green = active account has headroom, yellow = low, red = spent.
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "drop.halffull")
            ForEach(Provider.allCases) { p in
                if let a = store.activeAccount(for: p), let h = a.headroom {
                    Circle().fill(h <= 0.5 ? Color.red : h <= 20 ? Color.yellow : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}
