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

                Text("devices.list").font(.subheadline.weight(.semibold))
                deviceRow(nil, title: Text("devices.all"), subtitle: Text("devices.requests \(proxy.flows.count)"))
                ForEach(proxy.sortedDevices) { d in
                    deviceRow(d.address, title: Text(verbatim: d.name ?? d.address),
                              subtitle: Text(verbatim: "\(d.address) · \(formatBytes(d.sent + d.received))"))
                }
                if proxy.devices.isEmpty {
                    Text("devices.none").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func deviceRow(_ address: String?, title: Text, subtitle: Text) -> some View {
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
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(selectedDevice == address ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Menu {
                Button("devices.export.har") { DeviceExport.save(visible, as: .har) }
                Button("devices.export.csv") { DeviceExport.save(visible, as: .csv) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(visible.isEmpty)
            .help(Text("devices.export"))
            Button("devices.clear", systemImage: "trash") { proxy.clear() }
                .labelStyle(.iconOnly)
                .help(Text("devices.clear"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                Text(verbatim: f.port == (f.isHTTPS ? 443 : 80) ? f.host : "\(f.host):\(f.port)").lineLimit(1)
            }
            .width(min: 140, ideal: 220)
            TableColumn("devices.col.path") { f in
                Text(verbatim: f.path ?? "🔒").lineLimit(1).foregroundStyle(f.path == nil ? .secondary : .primary)
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
                var h = hosts[f.host] ?? HostSummary(host: f.host)
                h.requests += 1
                h.bytes += f.sent + f.received
                h.last = max(h.last, f.started)
                if f.error != nil { h.errors += 1 }
                hosts[f.host] = h
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
        if f.error != nil {
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
                        if let path = f.path { row("devices.col.path", path) }
                        if let status = f.status { row("devices.col.status", String(status)) }
                        row("devices.device", f.device)
                        row("devices.sent", formatBytes(f.sent))
                        row("devices.received", formatBytes(f.received))
                        if let d = f.duration { row("devices.col.duration", String(format: "%.2f s", d)) }
                        GridRow {
                            Text("devices.col.time").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(f.started, format: .dateTime.day().month().hour().minute().second())
                        }
                        if let error = f.error { row("devices.error", error) }
                    }
                    .font(.callout)
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
