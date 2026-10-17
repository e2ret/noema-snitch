import Darwin
import Foundation

/// A Unix-socket connection that exchanges newline-terminated JSON messages.
public final class LineChannel {
    public let fd: Int32
    public var onLine: ((Data) -> Void)?
    public var onClose: (() -> Void)?

    private let queue: DispatchQueue
    private let writeQueue = DispatchQueue(label: "noema.channel.write")
    private var source: DispatchSourceRead?
    private var buffer = Data()
    private var closed = false

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in Darwin.close(fd) }
        source = src
        src.resume()
    }

    public func send<T: Encodable>(_ message: T) {
        guard let data = IPC.encode(message) else { return }
        send(data: data)
    }

    public func send(data: Data) {
        writeQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            var payload = data
            payload.append(0x0A)
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(self.fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    /// Call on `queue`.
    public func disconnect() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
        if n <= 0 {
            disconnect()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }
}

public enum UnixSocket {
    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
        }
        return addr
    }

    public static func listen(path: String) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    public static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
