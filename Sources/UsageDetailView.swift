import SwiftUI
import AppKit

/// Drives the details window: which period is shown, which projects are expanded, and the latest report.
final class UsageDetailModel: ObservableObject {
    @Published var period: UsagePeriod = .today
    @Published var report: UsageReport?
    @Published var expanded: Set<String> = []
    var pendingFocus: String?          // project name to open once the report arrives
    private var autoExpanded = false

    func load() {
        let wanted = period
        UsageStore.shared.report(wanted) { [weak self] r in
            guard let self = self, r.period == self.period else { return }
            self.report = r
            if let name = self.pendingFocus, let p = r.projects.first(where: { $0.name == name }) {
                self.expanded.insert(p.id)
                self.pendingFocus = nil
                self.autoExpanded = true
            } else if !self.autoExpanded, let first = r.projects.first {
                self.expanded.insert(first.id)     // open the biggest project the first time
                self.autoExpanded = true
            }
        }
    }

    func choose(_ p: UsagePeriod) {
        guard p != period else { return }
        period = p
        report = nil
        load()
    }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

private enum Theme {
    static let orange = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let palette: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),   // Claude orange
        Color(red: 0.36, green: 0.43, blue: 0.88),      // blue
        Color(red: 0.27, green: 0.69, blue: 0.42),      // green
        Color(red: 0.91, green: 0.72, blue: 0.30),      // gold
        Color(red: 0.62, green: 0.42, blue: 0.80),      // violet
        Color(red: 0.30, green: 0.70, blue: 0.75),      // teal
        Color(red: 0.90, green: 0.45, blue: 0.62),      // pink
        Color(red: 0.55, green: 0.58, blue: 0.64),      // grey
    ]
    static func color(_ i: Int) -> Color { palette[i % palette.count] }
}

struct UsageDetailView: View {
    @ObservedObject var model: UsageDetailModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let r = model.report {
                if r.projects.isEmpty { emptyState(r) } else { projectList(r) }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tokens by project").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Picker("Period", selection: Binding(get: { model.period }, set: { model.choose($0) })) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
            if let r = model.report {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStore.format(r.total.fresh))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("tokens").foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("plus \(UsageStore.format(r.total.cacheRead)) re-read from cache")
                        Text("\(r.responses) responses · \(r.projects.count) \(r.projects.count == 1 ? "project" : "projects")")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if r.projects.count > 1 { shareBar(r) }
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
    }

    private func shareBar(_ r: UsageReport) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(r.projects.enumerated()), id: \.element.id) { i, p in
                    let share = CGFloat(p.tokens.fresh) / CGFloat(max(1, r.total.fresh))
                    Theme.color(i).frame(width: max(3, geo.size.width * share))
                        .help("\(p.name): \(UsageStore.format(p.tokens.fresh))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 8)
    }

    // MARK: List

    private func projectList(_ r: UsageReport) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(Array(r.projects.enumerated()), id: \.element.id) { i, p in
                    ProjectCard(project: p, color: Theme.color(i), total: r.total.fresh, period: r.period,
                                isOpen: model.expanded.contains(p.id)) {
                        withAnimation(.easeInOut(duration: 0.18)) { model.toggle(p.id) }
                    }
                }
            }
            .padding(16)
        }
    }

    private func emptyState(_ r: UsageReport) -> some View {
        VStack(spacing: 6) {
            Text("No usage \(r.period == .today ? "yet today" : "in this period")")
                .font(.system(size: 14, weight: .semibold))
            Text("Claude Code usage on this Mac shows up here as you work.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("From Claude Code logs on this Mac · subagent work is included in its project")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            Spacer()
            Button("Refresh") { model.load() }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    let project: ProjectUsage
    let color: Color
    let total: Int
    let period: UsagePeriod
    let isOpen: Bool
    let toggle: () -> Void

    private var share: Double { Double(project.tokens.fresh) / Double(max(1, total)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { summary }.buttonStyle(.plain)
            if isOpen {
                Divider().padding(.horizontal, 14)
                details.padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private var summary: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                Circle().fill(color).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(project.path).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(UsageStore.format(project.tokens.fresh))
                        .font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("\(Int((share * 100).rounded()))%").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * share))
                }
            }
            .frame(height: 5)
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                stat("Input", project.tokens.input)
                stat("Output", project.tokens.output)
                stat("Cache write", project.tokens.cacheWrite)
                stat("Cache read", project.tokens.cacheRead, dim: true)
                stat("Responses", project.responses, raw: true)
            }
            if !project.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("MODELS")
                    ForEach(project.models) { m in
                        HStack {
                            Text(m.name).font(.system(size: 12))
                            Spacer()
                            Text(UsageStore.format(m.tokens.fresh)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                            Text("\(Int((Double(m.tokens.fresh) / Double(max(1, project.tokens.fresh)) * 100).rounded()))%")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("SESSIONS · \(project.sessions.count)")
                ForEach(project.sessions.prefix(8)) { s in sessionRow(s) }
                if project.sessions.count > 8 {
                    Text("+ \(project.sessions.count - 8) smaller sessions")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func stat(_ label: String, _ value: Int, dim: Bool = false, raw: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(raw ? "\(value)" : UsageStore.format(value))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(dim ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ s: SessionUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title ?? "Untitled session").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(timeLabel(s)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageStore.format(s.tokens.fresh)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                if s.subagentFresh > 0 {
                    Text("\(UsageStore.format(s.subagentFresh)) from subagents")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func timeLabel(_ s: SessionUsage) -> String {
        let cal = Calendar.current
        let day = DateFormatter()
        day.dateFormat = "MMM d"
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        let resp = "\(s.responses) \(s.responses == 1 ? "response" : "responses")"
        if cal.isDate(s.first, inSameDayAs: s.last) {
            let when = cal.isDateInToday(s.first) ? "Today" : day.string(from: s.first)
            let span = clock.string(from: s.first) == clock.string(from: s.last)
                ? clock.string(from: s.first) : "\(clock.string(from: s.first)) – \(clock.string(from: s.last))"
            return "\(when) · \(span) · \(resp)"
        }
        return "\(day.string(from: s.first)) – \(day.string(from: s.last)) · \(resp)"
    }
}

// MARK: - Window

/// Owns the details window. Clawd is an accessory app, so the window brings the app forward when it opens.
final class UsageDetailWindow: NSObject, NSWindowDelegate {
    static let shared = UsageDetailWindow()

    private var window: NSWindow?
    private let model = UsageDetailModel()
    private var timer: Timer?

    func show(period: UsagePeriod, focus: String? = nil) {
        if window == nil {
            let host = NSHostingController(rootView: UsageDetailView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Clawd · Token usage"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 620, height: 660))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.pendingFocus = focus
        if model.period != period {
            model.period = period
            model.report = nil
        }
        model.load()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.model.load() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
