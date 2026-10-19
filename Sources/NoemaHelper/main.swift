import Darwin
import Foundation
import NoemaShared

// Noema Snitch helper: runs as root (LaunchDaemon), redirects outgoing TCP
// through pf into its proxy and allows or denies each connection.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

guard getuid() == 0 else {
    log("must run as root")
    exit(1)
}

// Our sockets carry this group id, which pf uses to skip redirecting them.
guard let group = getgrnam("_noemasnitch") else {
    log("group _noemasnitch is missing; run scripts/install-helper.sh")
    exit(1)
}
let helperGroup = group.pointee.gr_gid
guard setgid(helperGroup) == 0 else {
    log("setgid failed: \(String(cString: strerror(errno)))")
    exit(1)
}

let pf = PFController(proxyPort: Proxy.port, groupID: helperGroup)
pf.uninstall()  // leftovers from a crash

let engine = DecisionEngine()
let ipc = IPCServer(engine: engine)
engine.ipc = ipc
let ledger = TrafficLedger()
let proxy = Proxy(pf: pf, engine: engine, ledger: ledger)

do {
    try proxy.start()
    try ipc.start()
} catch {
    log("startup failed: \(error)")
    exit(1)
}

func applySettings(_ settings: HelperSettings) {
    if settings.filteringEnabled {
        pf.install(blockQUIC: settings.blockQUIC, bypassLocalNetwork: settings.allowLocalNetwork)
    } else {
        pf.uninstall()
    }
}
engine.onSettingsChanged = applySettings
applySettings(engine.settings)

// Traffic counters go to the app once a second.
let trafficTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
trafficTimer.schedule(deadline: .now() + 1, repeating: 1)
trafficTimer.setEventHandler {
    let entries = ledger.drain()
    if !entries.isEmpty { ipc.broadcast(.traffic(date: Date(), entries: entries)) }
}
trafficTimer.resume()

// Remove the redirect on shutdown so the network keeps working without us.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        pf.uninstall()
        unlink(IPC.socketPath)
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

log("Noema Snitch helper started")
dispatchMain()
