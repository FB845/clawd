import AppKit

let args = CommandLine.arguments

// `Clawd hook`, `Clawd notify "hi"`, …: the command-line client. Never starts the UI.
if args.count > 1, CLI.commands.contains(args[1]) {
    CLI.run(Array(args.dropFirst()))
}

// Headless helpers used by build.sh.
if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
    IconRenderer.writeIconset(to: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
    IconRenderer.writePreview(to: args[i + 1], dark: false)
    exit(0)
}
if let i = args.firstIndex(of: "--usage-report"), i + 1 < args.count, let period = UsagePeriod(rawValue: args[i + 1]) {
    _ = UsageStore.shared.scanNow()
    let sem = DispatchSemaphore(value: 0)
    UsageStore.shared.report(period) { r in
        print("total fresh", r.total.fresh, "cacheRead", r.total.cacheRead, "responses", r.responses)
        for p in r.projects {
            print(" \(p.name) [\(p.path)] fresh \(p.tokens.fresh) out \(p.tokens.output) cw \(p.tokens.cacheWrite) resp \(p.responses) sessions \(p.sessions.count)")
            for m in p.models { print("    model \(m.name) \(m.tokens.fresh)") }
            for x in p.sessions.prefix(3) { print("    session \(x.title ?? "(untitled)") \(x.tokens.fresh) sub \(x.subagentFresh)") }
        }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}
if let i = args.firstIndex(of: "--render-usage-detail"), i + 2 < args.count, let period = UsagePeriod(rawValue: args[i + 2]) {
    _ = NSApplication.shared
    IconRenderer.writeUsageDetail(to: args[i + 1], period: period)
    exit(0)
}
if let i = args.firstIndex(of: "--render-status"), i + 1 < args.count {
    IconRenderer.writeStatus(to: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--render-usage"), i + 1 < args.count {
    IconRenderer.writeUsage(to: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--render-approval"), i + 1 < args.count {
    IconRenderer.writeApproval(to: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--render-spinner"), i + 1 < args.count {
    IconRenderer.writeSpinner(to: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--render-preview-dark"), i + 1 < args.count {
    IconRenderer.writePreview(to: args[i + 1], dark: true)
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PetController?
    var statusItem: NSStatusItem?
    var usage: UsageMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = PetController()
        controller = c
        let item = NSStatusBar.system.statusItem(withLength: c.isPrimary ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        item.button?.image = IconRenderer.statusImage()
        item.button?.toolTip = c.isPrimary ? "Clawd" : "Clawd (friend)"
        let menu = c.makeMenu()
        item.menu = menu
        statusItem = item
        if c.isPrimary { usage = UsageMenuController(item: item, menu: menu) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
