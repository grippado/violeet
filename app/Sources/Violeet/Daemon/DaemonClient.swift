// The Unix-socket client: JSON-lines over `~/.violeet/daemon.sock`.
//
// # The daemon being down is an ordinary state
//
// ADR-002 puts the daemon in its own process precisely so that losing it loses
// the sidebar and not the terminals. This class is where that promise is kept:
// nothing in it can block a keystroke, and nothing in it reports a failure to
// the user as an error. A missing daemon is a status, the app reconnects behind
// the user's back, and tabs keep running throughout.
//
// # Reconnect reconciles rather than replays
//
// A daemon that restarted has forgotten every tab. On each successful connect
// the client re-sends `register_tab` for every live tab and then
// `request_snapshot`. That is why there is no outbound queue for messages sent
// while disconnected: the only ones that would matter are `register_tab` (the
// reconciliation resends it) and `close_tab` for a tab the daemon never learned
// about (which it would ignore anyway). Queueing them would replay a history
// the daemon has no use for.
//
// # Threading
//
// One serial queue owns the connection state and all writes. One dedicated
// thread does nothing but block in `read(2)`. Callbacks are delivered on the
// main queue, so consumers are plain `@MainActor` UI code.

import Foundation

final class DaemonClient: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        /// The daemon speaks a protocol this build does not. Distinguished from
        /// `disconnected` because reconnecting will not fix it, and because a
        /// silent stream of dropped lines is the worst way to learn about it.
        case protocolMismatch(daemonVersion: Int)
    }

    /// `docs/PROTOCOL.md`: a line longer than this is dropped, not buffered.
    private static let maxLineBytes = 1024 * 1024

    /// Reconnect delays, in seconds. Capped rather than unbounded: the daemon
    /// is a local process a user may restart by hand, and a fifteen-second
    /// worst case is short enough that they never wonder whether it worked.
    private static let backoff: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 15]

    @Published private(set) var status: Status = .disconnected

    /// Delivered on the main queue, one call per decoded message.
    var onMessage: ((DaemonMessage) -> Void)?

    /// Asked on every successful connect, on the main queue, for the tabs that
    /// must be re-announced. See the reconciliation note above.
    var liveTabs: (() -> [(tabID: String, cwd: String?)])?

    /// Called on the main queue after each reconnect has re-announced the tabs
    /// and asked for a snapshot.
    ///
    /// It exists for one thing: a rename typed while the daemon was down. The
    /// client drops what it cannot deliver, which is right for a stream of
    /// telemetry and wrong for something a person typed and watched appear.
    var onReconcile: (() -> Void)?

    private let queue = DispatchQueue(label: "digital.opengateway.violeet.daemon")
    private var fd: Int32 = -1
    private var readerThread: Thread?
    private var attempt = 0
    private var started = false
    /// Set while tearing down so the reader thread's exit does not schedule a
    /// reconnect we already decided against.
    private var generation = 0

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            connect()
        }
    }

    /// Stop reconnecting and close the socket. Safe to call more than once.
    func stop() {
        queue.async { [self] in
            started = false
            generation &+= 1
            closeSocketLocked()
            publish(.disconnected)
        }
    }

    // MARK: - Sending

    /// Write one message, or drop it if we are not connected.
    ///
    /// Dropping is deliberate — see the reconciliation note at the top. The
    /// caller never has to check the status first, which is what keeps daemon
    /// availability out of the tab lifecycle code.
    func send(_ message: AppMessage) {
        queue.async { [self] in
            guard fd >= 0, let line = message.line() else { return }
            writeAllLocked(line)
        }
    }

    // MARK: - Connection

    private func connect() {
        guard started else { return }
        publish(.connecting)

        let path = Discovery.socketPath()
        let dialStarted = Date()

        // Read the discovery file before connecting so a version mismatch is
        // named instead of showing up as an unexplained silence.
        if let info = Discovery.read(), info.protocolVersion > Protocol.version {
            publish(.protocolMismatch(daemonVersion: info.protocolVersion))
            scheduleReconnect()
            return
        }

        guard let socket = Self.openSocket(at: path) else {
            publish(.disconnected)
            scheduleReconnect()
            return
        }

        fd = socket
        attempt = 0
        DispatchQueue.main.async { [weak self] in
            self?.telemetry.connected(after: Date().timeIntervalSince(dialStarted))
        }
        publish(.connected)

        let generation = self.generation
        let thread = Thread { [weak self] in self?.readLoop(fd: socket, generation: generation) }
        thread.name = "violeet.daemon.reader"
        thread.stackSize = 512 * 1024
        readerThread = thread
        thread.start()

        reconcile()
    }

    /// Re-announce our tabs, then ask for the daemon's world.
    ///
    /// Order matters: `register_tab` first so a session the snapshot is about
    /// to describe can already be bound to the tab it belongs to.
    private func reconcile() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tabs = liveTabs?() ?? []
            for tab in tabs {
                send(.registerTab(tabID: tab.tabID, cwd: tab.cwd))
            }
            send(.requestSnapshot)
            // After the snapshot request, so anything the app replays here is
            // sent into a connection the daemon is already reconciling.
            onReconcile?()
        }
    }

    private func scheduleReconnect() {
        guard started else { return }
        let delay = Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, started, fd < 0 else { return }
            connect()
        }
    }

    /// Called from the reader thread when the connection ends, for any reason.
    private func connectionLost(generation: Int) {
        queue.async { [self] in
            guard generation == self.generation else { return }
            closeSocketLocked()
            publish(.disconnected)
            scheduleReconnect()
        }
    }

    private func closeSocketLocked() {
        guard fd >= 0 else { return }
        // Shut down first: it is what unblocks the reader thread sitting in
        // `read(2)`. Closing alone leaves it parked on a descriptor number that
        // may already have been reused.
        shutdown(fd, SHUT_RDWR)
        close(fd)
        fd = -1
        readerThread = nil
    }

    /// Throughput, latency and uptime of this link. See `DaemonTelemetry`.
    ///
    /// Main-actor isolated because everything that reads it is a view, and the
    /// reader thread already hops to main to deliver each message. Built lazily
    /// so this client can still be constructed off the main actor.
    @MainActor let telemetry = DaemonTelemetry()

    private func publish(_ new: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, status != new else { return }
            status = new
            // Cleared on the way down rather than left standing. A rate from
            // the last connection, shown beside a dot that says disconnected,
            // is a reading about a link that no longer exists.
            if new != .connected { telemetry.disconnected() }
        }
    }

    // MARK: - I/O

    private static func openSocket(at path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // A path that does not fit is not a transient failure, but it is also
        // not worth a distinct status: it can only happen if HOME is absurd.
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }

        // Writing to a socket the daemon closed must return EPIPE, not raise
        // SIGPIPE — the default disposition of which would kill the app and
        // every PTY in it.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        return fd
    }

    /// Blocking read loop. Owns no state but its own buffer.
    private func readLoop(fd: Int32, generation: Int) {
        var pending = Data()
        /// Set once a line has grown past the cap: everything up to the next
        /// newline is discarded rather than buffered.
        var discardingOversizedLine = false
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break } // clean EOF: the daemon went away
            if count < 0 {
                if errno == EINTR { continue }
                break
            }

            pending.append(contentsOf: chunk[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)

                if discardingOversizedLine {
                    discardingOversizedLine = false
                    continue
                }
                guard !line.isEmpty else { continue }
                handle(line: Data(line))
            }

            if pending.count > Self.maxLineBytes {
                pending.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                log("dropped a line over \(Self.maxLineBytes) bytes")
            }
        }

        connectionLost(generation: generation)
    }

    private func handle(line: Data) {
        switch DaemonMessageDecoder.decode(line: line) {
        case .success(let message):
            DispatchQueue.main.async { [weak self] in
                self?.telemetry.received()
                self?.onMessage?(message)
            }

        case .failure(.unknownType(let type)):
            // Not a problem. This is exactly what lets the daemon ship a new
            // message before the app knows about it.
            log("ignoring unknown message type \(type)")

        case .failure(.unsupportedVersion(let v)):
            log("dropped a message with protocol v\(v); this build speaks v\(Protocol.version)")
            publish(.protocolMismatch(daemonVersion: v))

        case .failure(.malformed(let why)):
            log("dropped a malformed line: \(why)")
        }
    }

    /// Write the whole buffer, tolerating short writes.
    ///
    /// Runs on the connection queue, so a full socket buffer stalls outbound
    /// daemon traffic and nothing else — never the terminal, never the UI.
    private func writeAllLocked(_ data: Data) {
        var offset = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                // EPIPE or anything else: the reader thread is about to notice
                // the same thing and drive the reconnect. Give up on this line.
                log("write failed (errno \(errno)); dropping the message")
                return
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("violeet: daemon: \(message)\n".utf8))
    }
}
