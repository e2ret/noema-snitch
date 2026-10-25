import SwiftUI

/// "Devices": a Charles-style proxy for iPhone/iPad and the traffic they send through it.
struct DevicesView: View {
    @EnvironmentObject private var proxy: DeviceProxyModel
    @State private var selectedDevice: String?
    @State private var selection: DeviceFlow.ID?
    @State private var search = ""
    @AppStorage("devices.grouped") private var grouped = false

    private var visible: [DeviceFlow] {
        proxy.flows.filter { f in
            (selectedDevice == nil || f.device == selectedDevice)
                && (search.isEmpty
                    || f.displayHost.localizedCaseInsensitiveContains(search)
                    || f.host.localizedCaseInsensitiveContains(search)
                    || (f.displayApp?.name ?? "").localizedCaseInsensitiveContains(search)
                    || (f.path ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if grouped { groupedList } else { table }
            }
            Divider()
            FlowInspector(flow: proxy.flows.first { $0.id == selection })
                .frame(width: 300)
        }
        .onAppear {
            // Screenshots: show a selected HTTPS request with its TLS and timing details.
            if Demo.isEnabled { selection = proxy.flows.first { $0.tls != nil }?.id }
        }
    }

    // MARK: - Sidebar: switch, how to connect, devices

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("devices.proxy", systemImage: "iphone.radiowaves.left.and.right")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { proxy.isRunning }, set: { proxy.setEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if let error = proxy.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("devices.howto.title").font(.subheadline.weight(.semibold))
                    Text("devices.howto.steps")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        GridRow {
                            Text("devices.server").foregroundStyle(.secondary)
                            Text(verbatim: proxy.macAddresses.joined(separator: "\n"))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                        }
                        GridRow {
                            Text("devices.port").foregroundStyle(.secondary)
                            TextField("", value: $proxy.port, format: .number.grouping(.never))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .frame(width: 70)
                                .disabled(proxy.isRunning)
                        }
                    }
                    Text("devices.https.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                settingsCard

                Text("devices.list").font(.subheadline.weight(.semibold))
                deviceRow(nil, title: Text("devices.all"), subtitle: Text("devices.requests \(proxy.flows.count)"))
                ForEach(proxy.sortedDevices) { d in
                    deviceRow(d.address, title: Text(verbatim: d.name ?? d.address),
                              subtitle: Text(verbatim: "\(d.address) · \(formatBytes(d.sent + d.received))"),
                              device: d)
                }
                if proxy.devices.isEmpty {
                    Text("devices.none").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    /// Access control, throttling and the external proxy.
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("devices.settings").font(.subheadline.weight(.semibold))

            Text("devices.access").font(.caption).foregroundStyle(.secondary)
            Picker("devices.access", selection: $proxy.config.access) {
                Text("devices.access.local").tag(DeviceProxyConfig.Access.localNetwork)
                Text("devices.access.selected").tag(DeviceProxyConfig.Access.selected)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            Text(proxy.config.access == .selected ? "devices.access.selected.note" : "devices.access.local.note")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("devices.throttle").font(.caption).foregroundStyle(.secondary)
            Picker("devices.throttle", selection: $proxy.config.throttle) {
                ForEach(ThrottleProfile.allCases) { p in
                    Text(LocalizedStringKey("throttle." + p.rawValue)).tag(p)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Toggle("devices.upstream", isOn: $proxy.config.upstreamEnabled)
            if proxy.config.upstreamEnabled {
                HStack(spacing: 4) {
                    TextField("devices.upstream.host", text: $proxy.config.upstreamHost)
                        .font(.system(.body, design: .monospaced))
                    Text(verbatim: ":")
                    TextField("", value: $proxy.config.upstreamPort, format: .number.grouping(.never))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 60)
                }
                Text("devices.upstream.note")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func deviceRow(_ address: String?, title: Text, subtitle: Text, device: DeviceProxyModel.Device? = nil) -> some View {
        Button {
            selectedDevice = address
        } label: {
            HStack(spacing: 10) {
                Image(systemName: address == nil ? "square.stack.3d.up" : "iphone")
                    .font(.system(size: 18))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    title.lineLimit(1)
                    subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let address, !proxy.isAllowed(address) {
                        HStack(spacing: 6) {
                            Label("devices.notAllowed", systemImage: "hand.raised.fill")
                                .font(.caption).foregroundStyle(.red)
                            Button("devices.allow") { proxy.allow(address) }
                                .controlSize(.mini)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(selectedDevice == address ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let address {
                if proxy.config.allowedDevices.contains(address) {
                    Button("devices.revoke") { proxy.revoke(address) }
                } else {
                    Button("devices.allow") { proxy.allow(address) }
                }
            }
        }
    }

    // MARK: - Requests

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("devices.search", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            Spacer()
            Picker("", selection: $grouped) {
                Text("devices.view.list").tag(false)
                Text("devices.view.grouped").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text("devices.requests \(visible.count)").font(.caption).foregroundStyle(.secondary)
            Button {
                proxy.toggleRecording()
            } label: {
                Image(systemName: proxy.config.recording ? "pause.circle" : "record.circle")
                    .foregroundStyle(proxy.config.recording ? Color.primary : Color.red)
            }
            .buttonStyle(.borderless)
            .help(Text(proxy.config.recording ? "devices.recording.pause" : "devices.recording.resume"))
            Menu {
                Button("devices.session.open") { proxy.openSession() }
                Button("devices.session.save") { proxy.saveSession() }
                    .disabled(proxy.flows.isEmpty)
                Divider()
                Button("devices.export.har") { DeviceExport.save(visible, as: .har) }
                    .disabled(visible.isEmpty)
                Button("devices.export.csv") { DeviceExport.save(visible, as: .csv) }
                    .disabled(visible.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("devices.export"))
            Button("devices.clear", systemImage: "trash") { proxy.clear() }
                .labelStyle(.iconOnly)
                .help(Text("devices.clear"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let name = proxy.openedSession {
                HStack {
                    Label("devices.session.viewing \(name)", systemImage: "doc.text")
                    Spacer()
                    Button("devices.session.backToLive") { proxy.clear() }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            } else if !proxy.config.recording {
                HStack {
                    Label("devices.recording.paused", systemImage: "pause.circle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("devices.recording.resume") { proxy.toggleRecording() }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("devices.col.time") { f in
                Text(f.started, format: .dateTime.hour().minute().second()).monospacedDigit()
            }
            .width(min: 64, ideal: 70)
            TableColumn("devices.col.app") { f in
                appLabel(f)
            }
            .width(min: 90, ideal: 130)
            TableColumn("devices.col.method") { f in
                Text(verbatim: f.isHTTPS ? "HTTPS" : f.method)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(f.isHTTPS ? Color.green : Color.blue)
            }
            .width(min: 50, ideal: 60)
            TableColumn("devices.col.host") { f in
                Text(verbatim: f.port == (f.isHTTPS ? 443 : 80) ? f.displayHost : "\(f.displayHost):\(f.port)")
                    .lineLimit(1)
                    .help(f.remoteIP.map { Text(verbatim: $0) } ?? Text(verbatim: f.host))
            }
            .width(min: 140, ideal: 220)
            TableColumn("devices.col.path") { f in
                if let path = f.path {
                    Text(verbatim: path).lineLimit(1)
                } else {
                    // HTTPS: no path, but the handshake tells the protocol.
                    let tls = [f.tls?.serverVersion, f.tls?.clientALPN.first].compactMap { $0 }.joined(separator: " · ")
                    Text(verbatim: "🔒 " + tls).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 160)
            TableColumn("devices.col.status") { f in
                statusView(f)
            }
            .width(min: 50, ideal: 60)
            TableColumn("devices.col.size") { f in
                Text(verbatim: "↑\(formatBytes(f.sent)) ↓\(formatBytes(f.received))")
                    .font(.caption).monospacedDigit().lineLimit(1)
            }
            .width(min: 110, ideal: 140)
            TableColumn("devices.col.duration") { f in
                Text(verbatim: f.duration.map { String(format: "%.1f s", $0) } ?? "…")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("devices.empty.title", systemImage: "iphone.radiowaves.left.and.right",
                                       description: Text(proxy.isRunning ? "devices.empty.waiting" : "devices.empty.off"))
            }
        }
    }

    @ViewBuilder
    private func appLabel(_ f: DeviceFlow) -> some View {
        if let app = f.displayApp {
            Text(verbatim: app.name)
                .italic(app.isGuess)
                .foregroundStyle(app.isGuess ? .secondary : .primary)
                .lineLimit(1)
                .help(Text(app.isGuess ? "devices.app.guess" : "devices.app.useragent"))
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }

    // MARK: - Grouped by app

    private struct HostSummary: Identifiable {
        let host: String
        var requests = 0
        var bytes: Int64 = 0
        var last = Date.distantPast
        var errors = 0
        var id: String { host }
    }

    private struct AppSummary: Identifiable {
        let name: String
        let isGuess: Bool
        var hosts: [HostSummary]
        var requests: Int
        var bytes: Int64
        var id: String { name }
    }

    private var groups: [AppSummary] {
        Dictionary(grouping: visible, by: \.appGroup).map { name, flows in
            var hosts: [String: HostSummary] = [:]
            for f in flows {
                var h = hosts[f.displayHost] ?? HostSummary(host: f.displayHost)
                h.requests += 1
                h.bytes += f.sent + f.received
                h.last = max(h.last, f.started)
                if f.error != nil { h.errors += 1 }
                hosts[f.displayHost] = h
            }
            return AppSummary(name: name,
                              isGuess: flows.first?.displayApp?.isGuess ?? true,
                              hosts: hosts.values.sorted { $0.bytes > $1.bytes },
                              requests: flows.count,
                              bytes: flows.reduce(0) { $0 + $1.sent + $1.received })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var groupedList: some View {
        List {
            ForEach(groups) { g in
                Section {
                    ForEach(g.hosts) { h in
                        Button {
                            search = h.host
                            grouped = false
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "globe").foregroundStyle(.secondary)
                                Text(verbatim: h.host).lineLimit(1)
                                if h.errors > 0 {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).font(.caption)
                                }
                                Spacer()
                                Text("devices.requests \(h.requests)").font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: formatBytes(h.bytes)).font(.caption).monospacedDigit()
                                    .frame(width: 70, alignment: .trailing)
                                Text(h.last, format: .dateTime.hour().minute().second())
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("devices.group.open"))
                    }
                } header: {
                    HStack {
                        Text(verbatim: g.name).font(.headline).italic(g.isGuess)
                        Spacer()
                        Text("devices.group.summary \(g.hosts.count) \(g.requests)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: formatBytes(g.bytes)).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("devices.empty.title", systemImage: "iphone.radiowaves.left.and.right",
                                       description: Text(proxy.isRunning ? "devices.empty.waiting" : "devices.empty.off"))
            }
        }
    }

    @ViewBuilder
    private func statusView(_ f: DeviceFlow) -> some View {
        if f.blocked {
            Image(systemName: "hand.raised.fill").foregroundStyle(.red).help(Text("devices.notAllowed"))
        } else if f.error != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if let status = f.status {
            Text(verbatim: String(status)).monospacedDigit()
                .foregroundStyle(status >= 400 ? Color.red : .primary)
        } else if f.ended == nil {
            ProgressView().controlSize(.mini)
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }
}

private struct FlowInspector: View {
    let flow: DeviceFlow?

    var body: some View {
        ScrollView {
            if let f = flow {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: f.displayApp?.name ?? f.host).font(.title3.bold())
                        .italic(f.displayApp?.isGuess == true).lineLimit(2)
                    Text(verbatim: f.url).font(.callout).textSelection(.enabled).foregroundStyle(.secondary)
                    if f.isHTTPS {
                        Label("devices.https.encrypted", systemImage: "lock.fill")
                            .font(.caption)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("devices.col.method", f.isHTTPS ? "CONNECT (HTTPS)" : f.method)
                        row("devices.col.host", "\(f.host):\(f.port)")
                        if let ip = f.remoteIP, ip != f.host { row("devices.remoteIP", ip) }
                        if f.viaUpstream { row("devices.route", RuleText.localized("devices.route.upstream")) }
                        if let path = f.path { row("devices.col.path", path) }
                        if let status = f.status { row("devices.col.status", String(status)) }
                        row("devices.device", f.device)
                        row("devices.sent", formatBytes(f.sent))
                        row("devices.received", formatBytes(f.received))
                        GridRow {
                            Text("devices.col.time").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(f.started, format: .dateTime.day().month().hour().minute().second())
                        }
                        if let error = f.error { row("devices.error", error) }
                    }
                    .font(.callout)

                    TimingView(flow: f)

                    if let tls = f.tls {
                        TLSView(tls: tls)
                    }
                    if let ua = f.userAgent {
                        Text("devices.useragent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: ua).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("devices.select")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .background(.background)
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Phases of a request as stacked bars: DNS, connect, TLS, first byte, total.
private struct TimingView: View {
    let flow: DeviceFlow

    private var phases: [(LocalizedStringKey, TimeInterval?, Color)] {
        [("timing.dns", flow.timing.dns, .purple),
         ("timing.connect", flow.timing.connect, .orange),
         ("timing.tls", flow.timing.tls, .green),
         ("timing.firstByte", flow.timing.firstByte, .blue),
         ("timing.total", flow.duration, .gray)]
    }

    var body: some View {
        let longest = max(phases.compactMap(\.1).max() ?? 0, 0.001)
        VStack(alignment: .leading, spacing: 5) {
            Text("timing.title").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                if let value = phase.1 {
                    HStack(spacing: 8) {
                        Text(phase.0).font(.caption).frame(width: 92, alignment: .trailing).foregroundStyle(.secondary)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(phase.2.opacity(0.7))
                                .frame(width: max(2, geo.size.width * value / longest))
                        }
                        .frame(height: 8)
                        Text(verbatim: Self.format(value)).font(.caption).monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        t < 1 ? String(format: "%.0f ms", t * 1000) : String(format: "%.2f s", t)
    }
}

/// What the TLS handshake revealed — like Charles' "SSL" tab.
private struct TLSView: View {
    let tls: TLSInfo
    @State private var showCiphers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("tls.title").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                if let sni = tls.sni { row("tls.sni", sni) }
                row("tls.protocol", tls.serverVersion ?? "—")
                row("tls.clientVersions", tls.clientVersions.filter { $0 != "GREASE" }.joined(separator: ", "))
                row("tls.cipher", tls.serverCipher ?? "—")
                row("tls.alpn", tls.clientALPN.isEmpty ? "—" : tls.clientALPN.joined(separator: ", "))
                if let chosen = tls.serverALPN { row("tls.alpnChosen", chosen) }
                if let resumed = tls.resumed {
                    row("tls.resumed", RuleText.localized(resumed ? "tls.yes" : "tls.no"))
                }
                row("tls.extensions", "\(tls.clientExtensions) / \(tls.serverExtensions)")
            }
            .font(.caption)
            DisclosureGroup(isExpanded: $showCiphers) {
                Text(verbatim: tls.clientCiphers.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("tls.clientCiphers \(tls.clientCiphers.count)").font(.caption)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
