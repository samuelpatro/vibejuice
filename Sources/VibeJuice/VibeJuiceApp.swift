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
        // One glass; inside it one colored band per provider with an active account, filled
        // to that account's headroom. So the cup says both how much and whose.
        let levels: [(Provider, Double)] = Provider.allCases.compactMap { p in
            store.activeAccount(for: p)?.headroom.map { (p, $0 / 100) }
        }
        HStack(spacing: 4) {
            Image(nsImage: MenuBarIcon.image(levels: levels, bolt: store.accounts.contains { $0.tokenMax != nil }))
            if store.showPercent, let lowest = levels.map(\.1).min() {
                Text("\(Int((lowest * 100).rounded()))%")
            }
        }
    }
}

enum MenuBarIcon {
    /// Provider colors for the columns inside the glass, echoing the icon's juice bands.
    static func tint(_ p: Provider) -> NSColor {
        switch p {
        case .claude: NSColor(red: 1.0, green: 0.62, blue: 0.28, alpha: 1)   // orange
        case .codex: NSColor(red: 0.30, green: 0.80, blue: 0.60, alpha: 1)   // green
        case .grok: NSColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 1)     // blue
        }
    }

    /// One glass with stacked colored bands, one per provider (0…1 fill), then a bolt. A color image,
    /// not a template, so the outline is drawn in the menu bar's current label color.
    static func image(levels: [(Provider, Double)], bolt: Bool) -> NSImage {
        let gw: CGFloat = 12, gh: CGFloat = 13, inset: CGFloat = 1.5
        let width = inset * 2 + gw + (bolt ? 12 : 0)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? NSColor.white : NSColor.black
        let img = NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Same tumbler as scripts/make-icon.swift, scaled to a menu bar glyph.
            let gx = inset, gy = inset
            let glass = CGMutablePath()
            glass.move(to: CGPoint(x: gx, y: gy + gh))
            glass.addLine(to: CGPoint(x: gx + gw * 0.10, y: gy + gh * 0.06))
            glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.18, y: gy), control: CGPoint(x: gx + gw * 0.11, y: gy))
            glass.addLine(to: CGPoint(x: gx + gw * 0.82, y: gy))
            glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.90, y: gy + gh * 0.06), control: CGPoint(x: gx + gw * 0.89, y: gy))
            glass.addLine(to: CGPoint(x: gx + gw, y: gy + gh))
            glass.closeSubpath()

            // Juice: full-width bands stacked bottom-up like the app icon's layers. Each provider
            // owns an equal share of the glass and its band fills that share to its headroom, so
            // the overall level is the total headroom and the colors say whose it is.
            if !levels.isEmpty {
                ctx.saveGState()
                ctx.addPath(glass); ctx.clip()
                let n = CGFloat(levels.count), gap: CGFloat = 1
                let share = (gh * 0.88 - gap * (n - 1)) / n
                var y = gy
                for (provider, level) in levels {
                    let h = share * CGFloat(max(0, min(1, level)))
                    ctx.setFillColor(tint(provider).cgColor)
                    ctx.fill(CGRect(x: gx, y: y, width: gw, height: h))
                    y += h + (h > 0 ? gap : 0)
                }
                ctx.restoreGState()
            }

            ctx.setStrokeColor(ink.cgColor)
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
                ink.set()
                symbol.draw(in: CGRect(x: rect.maxX - s.width - 1, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        img.isTemplate = false
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
