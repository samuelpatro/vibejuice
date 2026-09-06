import SwiftUI

@main
struct VibeJuiceApp: App {
    @State private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Menu bar only, no Dock icon, also when run via `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        Log.line("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
        NSSetUncaughtExceptionHandler { Log.line("uncaught exception: \($0.name.rawValue) \($0.reason ?? "")") }
        CrashLog.install()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(store)
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
            PopoverView().environment(store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(debugWindow ? .presented : .suppressed)
    }

    private let debugWindow = ProcessInfo.processInfo.environment["VIBEJUICE_DEBUG_WINDOW"] != nil
}

/// The app icon's glass as a template image. Its fill level is the smallest headroom among the
/// active accounts, and a bolt joins it while unused weekly quota is about to reset (tokenmax).
/// MenuBarExtra labels only draw text and images, so everything is baked into one image.
struct MenuBarLabel: View {
    var store: Store

    var body: some View {
        let lowest = Provider.allCases.compactMap { store.activeAccount(for: $0)?.headroom }.min()
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(level: lowest.map { $0 / 100 },
                                             bolt: store.accounts.contains { $0.tokenMax != nil }))
            if store.showPercent, let lowest {
                Text("\(Int(lowest.rounded()))%")
            }
        }
    }
}

enum MenuBarIcon {
    static func image(level: Double?, bolt: Bool) -> NSImage {
        let size = NSSize(width: bolt ? 30 : 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Same tumbler as scripts/make-icon.swift, scaled to a menu bar glyph.
            let gw: CGFloat = 10, gh: CGFloat = 13
            let gx: CGFloat = 1.5, gy: CGFloat = 1.5
            let glass = CGMutablePath()
            glass.move(to: CGPoint(x: gx, y: gy + gh))
            glass.addLine(to: CGPoint(x: gx + gw * 0.10, y: gy + gh * 0.06))
            glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.18, y: gy), control: CGPoint(x: gx + gw * 0.11, y: gy))
            glass.addLine(to: CGPoint(x: gx + gw * 0.82, y: gy))
            glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.90, y: gy + gh * 0.06), control: CGPoint(x: gx + gw * 0.89, y: gy))
            glass.addLine(to: CGPoint(x: gx + gw, y: gy + gh))
            glass.closeSubpath()

            // Juice: unknown headroom shows a neutral two-thirds so an empty glass always means spent.
            ctx.saveGState()
            ctx.addPath(glass); ctx.clip()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(x: gx, y: gy, width: gw, height: gh * 0.88 * CGFloat(level ?? 0.66)))
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.4)
            ctx.addPath(glass)
            ctx.strokePath()
            // Straw.
            ctx.move(to: CGPoint(x: gx + gw * 0.62, y: gy + gh * 0.55))
            ctx.addLine(to: CGPoint(x: gx + gw * 0.92, y: gy + gh * 1.25))
            ctx.strokePath()

            if bolt, let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold)) {
                let s = symbol.size
                symbol.draw(in: CGRect(x: rect.maxX - s.width - 1, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Marks clean exits in the log, so a missing marker after the last line means a crash or kill.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        Log.line("terminate (quit)")
    }
}

/// Writes the signal and a symbolized stack to the app log on a crash. This Mac keeps no crash
/// reports, so this is the only trace a crash leaves.
enum CrashLog {
    static func install() {
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Log.line("CRASH signal \(s)")
                for line in Thread.callStackSymbols.prefix(25) { Log.line("  \(line)") }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
