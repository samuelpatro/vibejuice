import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Provider.allCases) { p in
                    ProviderSection(provider: p)
                }
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 4)
            Divider()
            footer
            if let n = store.notice {
                Divider()
                Text(n)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .transition(.opacity)
            }
        }
        .frame(width: 440)
        .animation(.easeOut(duration: 0.15), value: store.notice)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(store.lastRefresh.map { "Updated \(Relative.text(from: $0))" } ?? "Loading…")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        store.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                            .animation(store.refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.refreshing)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Refresh")
                    Menu {
                        Toggle("Auto-switch when limit is hit", isOn: $store.autoSwitch)
                        Divider()
                        Button("Rescan logins") { store.reload() }
                        Divider()
                        Button("Quit VibeJuice") { NSApp.terminate(nil) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.small)
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
    @EnvironmentObject var store: Store
    let provider: Provider

    var body: some View {
        let rows = store.accounts(for: provider)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(provider.title).font(.system(size: 12.5, weight: .semibold))
                Text("\(rows.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        Button("Open \(provider.tool)") { store.open(provider) }
                            .buttonStyle(.glass).controlSize(.mini).fixedSize()
                        Button { store.addAccount(provider) } label: { Image(systemName: "plus") }
                            .buttonStyle(.glass).controlSize(.mini)
                            .help("Add \(provider.title) account")
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)

            if rows.isEmpty {
                Text("Not signed in. Press + to sign in.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.bottom, 10)
            } else {
                ForEach(rows) { a in
                    Button {
                        store.activate(a)
                    } label: {
                        AccountRow(account: a)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(a) }
                }
            }
        }
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
                Text(account.displayName)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if let plan = account.plan { Chip(text: plan) }
                if let r = account.renewsAt {
                    Text("renews \(r.formatted(.dateTime.month(.twoDigits).day()))")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize()
                }
                Spacer(minLength: 6)
                trailing
            }
            meters.padding(.leading, 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(account.isActive ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hovering = $0 }
        .opacity(account.spent ? 0.75 : 1)
    }

    @ViewBuilder
    private var meters: some View {
        switch account.status {
        case .ok(let windows):
            HStack(spacing: 14) {
                ForEach(windows) { w in Meter(window: w) }
            }
        case .loading:
            Text("Loading usage…").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        case .expired:
            Text(account.isActive
                 ? "Token expired. Start \(account.provider.tool) once and it refreshes."
                 : "Token expired. Switch to this account and start \(account.provider.tool) once.")
                .font(.system(size: 10.5)).foregroundStyle(.orange)
        case .error(let msg):
            Text(msg).font(.system(size: 10.5)).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .ok = account.status {
            let left = Int((account.headroom ?? 0).rounded())
            HStack(spacing: 6) {
                Text("\(left)% left")
                    .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(account.spent ? Color.red : left <= 20 ? Color.yellow : Color.primary)
                Text(subline).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
                if account.provider == .codex, let n = account.manualResets {
                    Chip(text: "\(n) reset\(n == 1 ? "" : "s")")
                }
            }
            .lineLimit(1).fixedSize()
        } else if case .expired = account.status {
            Text("Expired").font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
        }
    }

    private var subline: String {
        if account.spent, let r = account.soonestReset { return "back \(Relative.text(to: r)) · \(r.formatted(.dateTime.hour().minute()))" }
        if let r = account.nextReset { return "resets \(Relative.text(to: r))" }
        return account.status.windows.allSatisfy { $0.usedPercent == 0 } ? "unused" : ""
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule())
    }
}

/// One quota window on a single line: short label, bar, used percent.
struct Meter: View {
    let window: QuotaWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(shortLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(window.secondary ? .tertiary : .secondary)
                .lineLimit(1).fixedSize()
            Bar(used: window.usedPercent, secondary: window.secondary)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(window.exhausted ? Color.red : window.usedPercent >= 80 ? Color.yellow : (window.secondary ? Color.secondary : Color.primary))
                .frame(width: 30, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .help(helpText)
    }

    private var shortLabel: String {
        switch window.label {
        case "Session": return "5h"
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

struct Bar: View {
    let used: Double
    let secondary: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(0, min(1, used / 100)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }

    private var color: Color {
        if used >= 99.5 { return .red }
        if used >= 80 { return .yellow }
        return secondary ? Color.green.opacity(0.55) : .green
    }
}

// MARK: - Relative time

enum Relative {
    static func text(to date: Date) -> String {
        let s = date.timeIntervalSinceNow
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if s < 36 * 3600 { return "in \(Int((s / 3600).rounded())) h" }
        return "in \(Int((s / 86400).rounded())) days"
    }

    static func text(from date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int((s / 3600).rounded())) h ago"
    }
}
