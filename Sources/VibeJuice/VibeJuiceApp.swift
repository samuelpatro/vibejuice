import SwiftUI

@main
struct VibeJuiceApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Menu bar only, no Dock icon, also when run via `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        Log.line("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        NSSetUncaughtExceptionHandler { Log.line("uncaught exception: \($0.name.rawValue) \($0.reason ?? "")") }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("About VibeJuice", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

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
/// A bolt appears while any account has unused weekly quota about to reset (tokenmax).
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.accounts.contains { $0.tokenMax != nil } ? "bolt.fill" : "drop.halffull")
            ForEach(Provider.allCases) { p in
                if let a = store.activeAccount(for: p), let h = a.headroom {
                    Circle().fill(h <= 0.5 ? Color.red : h <= 20 ? Color.yellow : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
    }
}

/// Marks clean exits in the log, so a missing marker after the last line means a crash or kill.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Log.line("terminate (quit)")
    }
}
