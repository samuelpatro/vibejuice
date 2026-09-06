import SwiftUI

struct PopoverView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ForEach(Provider.allCases) { p in
                    ProviderSection(provider: p)
                }
            }
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 6)
            Divider()
            footer
            if let n = store.notice {
                Divider()
                HStack(spacing: 10) {
                    Text(n)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let r = store.pendingRestart {
                        Pill(text: "Restart \(r.sessions.count == 1 ? "session" : "\(r.sessions.count) sessions")", prominent: true)
                            .tapTarget("Restart \(r.sessions.count) \(r.provider.tool) sessions as \(r.account)") { store.restartPendingSessions() }
                            .help("Quits the running \(r.provider.tool) session\(r.sessions.count == 1 ? "" : "s") and reopens each one in its folder with \(r.provider.resumeCommand), signed in as \(r.account).")
                        Pill(text: "Later")
                            .tapTarget("Keep the old sessions running") { store.dismissRestart() }
                    }
                    if let u = store.undoable {
                        Pill(text: "Undo")
                            .tapTarget("Restore \(u.displayName)") { store.undoForget() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .transition(.opacity)
            }
        }
        .frame(width: 440)
        .background(HoverEnabler())
        .containerBackground(.clear, for: .window)
        .background(.thinMaterial)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: store.notice)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(store.refreshing ? "Refreshing…" : store.lastRefresh.map { "Updated \(Relative.text(from: $0))" } ?? "Loading…")
                .font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
            if let u = store.update {
                Pill(text: "\(u.version) is out")
                    .tapTarget("Version \(u.version) is available, open the release page") { NSWorkspace.shared.open(u.url) }
                    .help("Opens the release page. Homebrew users: brew upgrade --cask vibejuice")
            }
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    RefreshButton()
                        .tapTarget("Refresh usage", shape: AnyShape(Circle())) { store.reload() }
                        .help("Refresh (⌘R)")
                    Menu {
                        Toggle("Auto-switch when limit is hit", isOn: Binding(get: { store.autoSwitch }, set: { store.autoSwitch = $0 }))
                        Toggle("Percent in menu bar", isOn: Binding(get: { store.showPercent }, set: { store.showPercent = $0 }))
                        Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                        Divider()
                        Button("Rescan logins") { store.reload() }
                            .keyboardShortcut("r")
                        Divider()
                        Button("About VibeJuice") {
                            openWindow(id: "about")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        Button("Quit VibeJuice") { NSApp.terminate(nil) }
                            .keyboardShortcut("q")
                    } label: {
                        IconCircle(systemName: "ellipsis")
                            .accessibilityLabel("More")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Section

struct ProviderSection: View {
    @Environment(Store.self) private var store
    let provider: Provider

    var body: some View {
        let rows = store.accounts(for: provider)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(provider.title).font(.headline)
                Text("\(rows.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Pill(text: "Open \(provider.tool)")
                            .tapTarget("Open \(provider.tool) in a terminal") { store.open(provider) }
                        IconCircle(systemName: "plus", size: 24)
                            .tapTarget("Add \(provider.title) account", shape: AnyShape(Circle())) { store.addAccount(provider) }
                            .help("Add \(provider.title) account")
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)

            if rows.isEmpty {
                Text("Not signed in. Press + to sign in.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.bottom, 10)
            } else {
                ForEach(rows) { a in
                    // A tap gesture, not a Button: the row label re-renders on hover, and SwiftUI's
                    // button gesture crashes on this OS when its label changes mid-press.
                    AccountRow(account: a)
                        .tapTarget(rowLabel(a), shape: AnyShape(RoundedRectangle(cornerRadius: 8))) { store.activate(a) }
                        .contextMenu { rowMenu(a) }
                }
            }
        }
    }

    /// What VoiceOver reads for a row: who, plan, and the number that matters.
    private func rowLabel(_ a: Account) -> String {
        var parts = [a.displayName]
        if let plan = a.plan { parts.append(plan) }
        if let h = a.headroom { parts.append("\(Int(h.rounded())) percent left") }
        if case .expired = a.status { parts.append("token expired") }
        parts.append(a.isActive ? "active" : "switch to this account")
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func rowMenu(_ a: Account) -> some View {
        Button("Refresh") { Task { await store.refresh(a.id) } }
        if a.provider == .codex, let n = a.manualResets, n > 0 {
            Button("Use a manual reset (\(n) left)") { Task { await store.consumeReset(a) } }
        }
        Divider()
        Button("Forget account") { store.forget(a) }.disabled(a.isActive)
    }
}

// MARK: - Row

struct AccountRow: View {
    let account: Account
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle().strokeBorder(account.isActive ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    if account.isActive { Circle().fill(Color.accentColor).padding(3) }
                }
                .frame(width: 12, height: 12)
                Text(account.shortName)
                    .font(.body)
                    .lineLimit(1)
                    .fixedSize()
                    .help(account.displayName)
                if let plan = account.plan { Chip(text: plan) }
                Spacer(minLength: 6)
                trailing
            }
            HStack(alignment: .center, spacing: 12) {
                meters
                if account.provider == .codex, case .ok = account.status {
                    codexExtras
                }
                if let n = account.tokenMax {
                    TokenMaxChip(nudge: n)
                }
            }
            .padding(.leading, 20)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(account.isActive ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
        .opacity(account.spent ? 0.8 : 1)
    }

    @ViewBuilder
    private var meters: some View {
        switch account.status {
        case .ok(let windows):
            HStack(spacing: 14) {
                ForEach(windows) { w in Meter(window: w) }
            }
        case .loading:
            Text("Loading usage…").font(.caption).foregroundStyle(.secondary)
        case .noData:
            Text("No usage data for \(account.provider.tool) yet. Switching works.")
                .font(.caption).foregroundStyle(.secondary)
        case .expired:
            Text(account.isActive
                 ? "Token expired. Start \(account.provider.tool) once and it refreshes."
                 : "Token expired. Switch to this account and start \(account.provider.tool) once.")
                .font(.caption).foregroundStyle(.orange)
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .ok = account.status {
            let left = Int((account.headroom ?? 0).rounded())
            HStack(spacing: 6) {
                Text("\(left)% left")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(account.spent ? Color.red : left <= 20 ? Color.orange : Color.primary)
                Text(subline).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
        } else if case .expired = account.status {
            Text("Expired").font(.callout.weight(.medium)).foregroundStyle(.orange)
        } else if case .noData = account.status, account.isActive {
            Text("Active").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    /// Renewal date and manual resets sit at the end of the meter line, where Codex has room.
    private var codexExtras: some View {
        HStack(spacing: 8) {
            if let r = account.renewsAt {
                Text("renews \(r.formatted(.dateTime.day().month(.twoDigits)))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if let n = account.manualResets, n > 0 {
                Chip(text: "\(n) reset\(n == 1 ? "" : "s") left")
            }
        }
        .lineLimit(1).fixedSize()
    }

    private var subline: String {
        if account.spent, let r = account.soonestReset { return "back \(Relative.text(to: r)) · \(r.formatted(.dateTime.hour().minute()))" }
        if let r = account.nextReset { return "resets \(Relative.text(to: r))" }
        return account.status.windows.allSatisfy { $0.usedPercent == 0 } ? "unused" : ""
    }
}

/// "Use it before it resets": weekly quota mostly unused and the reset is hours away.
struct TokenMaxChip: View {
    let nudge: TokenMaxNudge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.caption2)
            Text("tokenmax \(nudge.hours) h")
                .font(.caption2.weight(.medium)).monospacedDigit()
        }
        .foregroundStyle(Color.purple)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.purple.opacity(0.14), in: Capsule())
        .help("\(nudge.window.label): \(Int(nudge.window.usedPercent.rounded()))% used, resets in \(nudge.hours) h. Less than half used and about to reset, so whatever is left is lost. Use it now.")
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// One quota window on a single line: short label, bar, used percent.
struct Meter: View {
    let window: QuotaWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(shortLabel)
                .font(.caption)
                .foregroundStyle(window.secondary ? .tertiary : .secondary)
                .lineLimit(1).fixedSize()
            Gauge(value: min(max(window.usedPercent, 0), 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(barColor)
                .opacity(window.secondary ? 0.7 : 1)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(window.exhausted ? Color.red : window.usedPercent >= 80 ? Color.orange : (window.secondary ? Color.secondary : Color.primary))
                .lineLimit(1).fixedSize()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .help(helpText)
    }

    private var barColor: Color {
        if window.exhausted { return .red }
        if window.usedPercent >= 80 { return .orange }
        return .green
    }

    private var shortLabel: String {
        switch window.label {
        case "Session", "5-hour": return "5h"
        case "Week, all models", "Weekly": return "Week"
        case "Daily": return "1d"
        default:
            // "Week, Fable 5" -> "Fable 5"
            if window.label.hasPrefix("Week, ") { return String(window.label.dropFirst(6)) }
            return window.label
        }
    }

    private var helpText: String {
        var t = "\(window.label): \(Int(window.usedPercent.rounded()))% used"
        if let r = window.resetsAt { t += " · \(window.exhausted ? "back" : "resets") \(Relative.text(to: r)) · \(r.formatted(.dateTime.month().day().hour().minute()))" }
        return t
    }
}

/// One shape for every icon button in the app: a circular interactive glass disc.
struct IconCircle: View {
    let systemName: String
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .medium))
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.tint(GlassTint.lift(scheme, contrast: contrast)).interactive(), in: .circle)
    }
}

/// Refresh control whose arrow spins while a refresh runs. TimelineView redraws every frame and
/// the closure reads `store.refreshing` live each frame, so the spin stops the moment a refresh
/// ends without needing the menu bar popover to re-render its tree, which it does not do reliably
/// on state changes while open. A plain rotated symbol, not an AppKit ProgressView, which keeps
/// animating on its own timer after the tree stops updating.
struct RefreshButton: View {
    @Environment(Store.self) private var store
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func angle(at date: Date) -> Double {
        store.refreshing && !reduceMotion ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 : 0
    }

    var body: some View {
        // Under Reduce Motion the timeline pauses and the arrow just dims while a refresh runs.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Image(systemName: "arrow.clockwise")
                .font(.system(size: size * 0.42, weight: .medium))
                .rotationEffect(.degrees(angle(at: context.date)))
                .opacity(reduceMotion && store.refreshing ? 0.4 : 1)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .glassEffect(.regular.tint(GlassTint.lift(scheme, contrast: contrast)).interactive(), in: .circle)
    }
}

/// Menu bar windows don't deliver hover events until they become key; ask for them explicitly.
struct HoverEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.acceptsMouseMovedEvents = true }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.acceptsMouseMovedEvents = true
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .padding(.top, 28)
            Text("VibeJuice")
                .font(.system(size: 26, weight: .bold))
            Text("Version \(version)")
                .font(.body).foregroundStyle(.secondary)
            Text("Switch Claude Code, Codex and Grok accounts in one click.\nKeep coding.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.top, 6)
            Link("View on GitHub", destination: URL(string: "https://github.com/samuelpatro/vibejuice")!)
                .font(.body)
                .padding(.top, 4)
                .padding(.bottom, 30)
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }
}

/// Capsule label used as a tappable control. Buttons whose labels change while pressed crash
/// SwiftUI's button gesture on this OS inside menu bar windows, so controls here are tap targets.
struct Pill: View {
    let text: String
    var prominent = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .contentShape(Capsule())
            .glassEffect(.regular.tint(prominent ? Color.accentColor : GlassTint.lift(scheme, contrast: contrast)).interactive(), in: .capsule)
    }
}

/// Plain glass sinks into the panel on a dark background. Native controls sit above it, so
/// non-prominent controls get a light tint that reads as a button in both appearances, and a
/// stronger one under Increase Contrast.
enum GlassTint {
    static func lift(_ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        let strong = contrast == .increased
        return scheme == .dark ? Color.white.opacity(strong ? 0.28 : 0.14) : Color.white.opacity(strong ? 0.85 : 0.6)
    }
}

/// Everything clickable in the popover, in one place: hit area, tap, keyboard focus with
/// Return and Space, and VoiceOver button semantics. Not SwiftUI's `Button`: its gesture
/// crashes on macOS 26 inside a menu bar window when the label re-renders mid-press.
struct TapTarget: ViewModifier {
    let label: String
    let shape: AnyShape
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(shape)
            .onTapGesture(perform: action)
            .focusable()
            .onKeyPress(.return) { action(); return .handled }
            .onKeyPress(.space) { action(); return .handled }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
    }
}

extension View {
    func tapTarget(_ label: String, shape: AnyShape = AnyShape(Capsule()), action: @escaping () -> Void) -> some View {
        modifier(TapTarget(label: label, shape: shape, action: action))
    }
}
