import Darwin
import Foundation

/// Finds the process behind a TCP flow through Apple's private NetworkStatistics
/// framework (what `nettop` uses). Unlike libproc it also sees flows of daemons
/// that use the user-space network stack, e.g. usbmuxd syncing with an iPhone.
final class FlowLookup {
    private typealias SourceCallback = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias DescriptionBlock = @convention(block) (CFDictionary?) -> Void
    private typealias DoneBlock = @convention(block) () -> Void
    private typealias CreateFn = @convention(c) (CFAllocator?, DispatchQueue, @escaping SourceCallback) -> UnsafeMutableRawPointer?
    private typealias AddAllFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias SetDescriptionFn = @convention(c) (UnsafeMutableRawPointer?, @escaping DescriptionBlock) -> Void
    private typealias QueryFn = @convention(c) (UnsafeMutableRawPointer?, @escaping DoneBlock) -> Void

    private let queue = DispatchQueue(label: "noema.nstat")
    private let lock = NSLock()
    private var manager: UnsafeMutableRawPointer?
    private var query: QueryFn?
    private var keyPID: String = ""
    private var keyLocal: String = ""
    /// Local TCP port → pid, rebuilt on every query.
    private var ports: [UInt16: Int32] = [:]

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_NOW),
              let create = dlsym(handle, "NStatManagerCreate"),
              let addTCP = dlsym(handle, "NStatManagerAddAllTCP"),
              let setDescription = dlsym(handle, "NStatSourceSetDescriptionBlock"),
              let queryAll = dlsym(handle, "NStatManagerQueryAllSourcesDescriptions"),
              let pidKey = dlsym(handle, "kNStatSrcKeyPID"),
              let localKey = dlsym(handle, "kNStatSrcKeyLocal") else {
            log("NetworkStatistics unavailable; system flows stay unidentified")
            return
        }
        keyPID = pidKey.assumingMemoryBound(to: CFString.self).pointee as String
        keyLocal = localKey.assumingMemoryBound(to: CFString.self).pointee as String
        let setDesc = unsafeBitCast(setDescription, to: SetDescriptionFn.self)
        query = unsafeBitCast(queryAll, to: QueryFn.self)

        manager = unsafeBitCast(create, to: CreateFn.self)(nil, queue) { [weak self] source, _ in
            setDesc(source) { dict in self?.record(dict) }
        }
        unsafeBitCast(addTCP, to: AddAllFn.self)(manager)
    }

    /// Pid owning the local TCP port, or nil. Blocks up to `timeout`.
    func pid(forLocalPort port: UInt16, timeout: TimeInterval = 0.3) -> Int32? {
        guard let manager, let query else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let done = DispatchSemaphore(value: 0)
        queue.sync { ports.removeAll(keepingCapacity: true) }
        query(manager) { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
        return queue.sync { ports[port] }
    }

    /// Runs on `queue`.
    private func record(_ dict: CFDictionary?) {
        guard let d = dict as? [String: Any],
              let pid = (d[keyPID] as? NSNumber)?.int32Value,
              let local = d[keyLocal] as? Data, local.count >= 4 else { return }
        // sockaddr_in / sockaddr_in6 both keep the port at offset 2, big-endian.
        let port = UInt16(local[local.startIndex + 2]) << 8 | UInt16(local[local.startIndex + 3])
        ports[port] = pid
    }
}
