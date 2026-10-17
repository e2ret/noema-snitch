import Darwin
import Foundation

/// Enumerates inet sockets of processes via libproc.
/// Without root only the current user's processes are readable.
public enum SocketScanner {
    public struct ProcessInfo {
        public let pid: pid_t
        public let executablePath: String
        public let processName: String

        public init(pid: pid_t, executablePath: String, processName: String) {
            self.pid = pid
            self.executablePath = executablePath
            self.processName = processName
        }
    }

    public static func scan() -> [Connection] {
        var result: [Connection] = []
        for pid in allPids() where pid > 0 {
            var path: String?
            var name: String?
            forEachInetSocket(of: pid) { fd, ini, proto, state in
                let remotePort = port(ini.insi_fport)
                guard remotePort != 0, let remote = address(ini, foreign: true) else { return false }
                if path == nil {
                    path = executablePath(of: pid) ?? ""
                    name = processName(of: pid) ?? ""
                }
                result.append(Connection(
                    pid: pid,
                    fd: fd,
                    processName: name ?? "",
                    executablePath: path ?? "",
                    appPath: AppIdentity.appPath(for: path ?? ""),
                    proto: proto,
                    localAddress: address(ini, foreign: false) ?? "",
                    localPort: port(ini.insi_lport),
                    remoteAddress: remote,
                    remotePort: remotePort,
                    tcpState: state
                ))
                return false
            }
        }
        return result
    }

    /// Process owning the TCP socket bound to `localPort` (the client side of a
    /// redirected connection). Needs root to see other users' processes.
    public static func owner(ofTCPPort localPort: Int, excluding excluded: pid_t) -> ProcessInfo? {
        for pid in allPids() where pid > 0 && pid != excluded {
            var found = false
            forEachInetSocket(of: pid) { _, ini, proto, _ in
                found = proto == "TCP" && port(ini.insi_lport) == localPort
                return found
            }
            if found {
                return ProcessInfo(pid: pid,
                                   executablePath: executablePath(of: pid) ?? "",
                                   processName: processName(of: pid) ?? "")
            }
        }
        return nil
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    public static func processName(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        return Array(pids.prefix(Int(max(n, 0))))
    }

    /// Calls `body` for each IPv4/IPv6 TCP or UDP socket; stop early by returning true.
    private static func forEachInetSocket(
        of pid: pid_t,
        _ body: (_ fd: Int32, _ ini: in_sockinfo, _ proto: String, _ tcpState: Int32?) -> Bool
    ) {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
        guard used > 0 else { return }

        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            let family = info.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }

            let stop: Bool
            switch info.psi.soi_kind {
            case Int32(SOCKINFO_TCP):
                stop = body(fd.proc_fd, info.psi.soi_proto.pri_tcp.tcpsi_ini, "TCP",
                            info.psi.soi_proto.pri_tcp.tcpsi_state)
            case Int32(SOCKINFO_IN):
                stop = body(fd.proc_fd, info.psi.soi_proto.pri_in, "UDP", nil)
            default:
                stop = false
            }
            if stop { return }
        }
    }

    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(truncatingIfNeeded: raw).bigEndian)
    }

    private static func address(_ ini: in_sockinfo, foreign: Bool) -> String? {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = foreign ? ini.insi_faddr.ina_46.i46a_addr4 : ini.insi_laddr.ina_46.i46a_addr4
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return String(cString: buf)
        }
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var addr = foreign ? ini.insi_faddr.ina_6 : ini.insi_laddr.ina_6
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return String(cString: buf)
        }
        return nil
    }
}
