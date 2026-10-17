import Foundation

/// One network socket of a process, as seen by libproc.
public struct Connection: Identifiable, Hashable {
    public let pid: pid_t
    public let fd: Int32
    public let processName: String
    public let executablePath: String
    /// Outermost `.app` bundle containing the executable, if any.
    public let appPath: String?
    public let proto: String
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String
    public let remotePort: Int
    /// TCP state index (TSI_S_*), nil for UDP.
    public let tcpState: Int32?

    public var id: String { "\(pid):\(fd):\(remoteAddress):\(remotePort)" }

    public var displayName: String {
        AppIdentity.displayName(executablePath: executablePath, processName: processName)
    }
}

public enum AppIdentity {
    /// Outermost `.app` bundle in the path, so helpers group under their app.
    public static func appPath(for executablePath: String) -> String? {
        var components: [Substring] = []
        for part in executablePath.split(separator: "/", omittingEmptySubsequences: false) {
            components.append(part)
            if part.hasSuffix(".app") { return components.joined(separator: "/") }
        }
        return nil
    }

    public static func displayName(executablePath: String, processName: String) -> String {
        if let app = appPath(for: executablePath) {
            return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        if !processName.isEmpty { return processName }
        return (executablePath as NSString).lastPathComponent
    }
}
