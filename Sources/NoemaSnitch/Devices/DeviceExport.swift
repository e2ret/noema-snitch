import AppKit
import Foundation
import UniformTypeIdentifiers

/// Saves device requests as HAR 1.2 (Chrome DevTools, Charles, Proxyman) or CSV.
enum DeviceExport {
    enum Format {
        case har, csv
    }

    @MainActor
    static func save(_ flows: [DeviceFlow], as format: Format) {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        switch format {
        case .har:
            panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
            panel.nameFieldStringValue = "NoemaSnitch-\(stamp).har"
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "NoemaSnitch-\(stamp).csv"
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = format == .har ? har(flows) : csv(flows)
        try? data.write(to: url, options: .atomic)
    }

    static func har(_ flows: [DeviceFlow]) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let entries: [[String: Any]] = flows.sorted { $0.started < $1.started }.map { f in
            let ms = (f.duration ?? 0) * 1000
            var requestHeaders: [[String: String]] = [["name": "Host", "value": f.host]]
            if let ua = f.userAgent { requestHeaders.append(["name": "User-Agent", "value": ua]) }
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: f.started),
                "time": ms,
                "request": [
                    "method": f.method,
                    "url": f.url,
                    "httpVersion": "HTTP/1.1",
                    "headers": requestHeaders,
                    "queryString": [],
                    "cookies": [],
                    "headersSize": -1,
                    "bodySize": f.sent,
                ] as [String: Any],
                "response": [
                    "status": f.status ?? 0,
                    "statusText": f.error ?? "",
                    "httpVersion": "HTTP/1.1",
                    "headers": [],
                    "cookies": [],
                    "content": ["size": f.received, "mimeType": ""] as [String: Any],
                    "redirectURL": "",
                    "headersSize": -1,
                    "bodySize": f.received,
                ] as [String: Any],
                "cache": [:] as [String: Any],
                "timings": ["send": 0, "wait": ms, "receive": 0],
                "connection": f.device,
            ]
            entry["comment"] = [f.device, f.displayApp?.name].compactMap { $0 }.joined(separator: " · ")
            return entry
        }
        let log: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "Noema Snitch", "version": version],
            "entries": entries,
        ] as [String: Any]]
        return (try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func csv(_ flows: [DeviceFlow]) -> Data {
        let iso = ISO8601DateFormatter()
        func field(_ value: String) -> String {
            value.contains(where: { ",\"\n".contains($0) }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        var lines = ["time,device,app,app_guessed,type,host,port,path,status,sent_bytes,received_bytes,duration_s,error,user_agent"]
        for f in flows.sorted(by: { $0.started < $1.started }) {
            let app: String = f.displayApp?.name ?? ""
            let guessed: String = f.displayApp?.isGuess == true ? "yes" : "no"
            let type: String = f.isHTTPS ? "HTTPS" : f.method
            let status: String = f.status.map { String($0) } ?? ""
            let duration: String = f.duration.map { String(format: "%.3f", $0) } ?? ""
            var row: [String] = [iso.string(from: f.started), f.device, app, guessed, type, f.host, String(f.port)]
            row += [f.path ?? "", status, String(f.sent), String(f.received), duration, f.error ?? "", f.userAgent ?? ""]
            lines.append(row.map(field).joined(separator: ","))
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\n") + "\n").utf8)  // BOM so Excel reads UTF-8
    }
}
