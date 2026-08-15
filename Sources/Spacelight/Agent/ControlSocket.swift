import Darwin
import Foundation

/// Verbs the client can send over the control socket. One newline-terminated ASCII word per
/// connection, no length framing and no version byte, because the vocabulary is tiny and fixed.
enum ControlVerb: String {
    case toggle
    case show
    case hide
    case quit
    case ping
}

/// Listens on the unix domain socket at `Paths.socketPath` and delivers each accepted verb to
/// `onVerb` on the main actor. Runs its accept loop on a background thread since `accept` blocks.
///
/// `@unchecked Sendable`: `listenFD` is written once on the main actor in `start()`/`stop()` and
/// read from the background accept thread only to call `accept`/`close`, which is the standard
/// "one owner writes, socket syscalls are the synchronization point" pattern for a listener socket.
final class ControlSocket: @unchecked Sendable {
    private let onVerb: @MainActor @Sendable (ControlVerb) -> Void
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let path: String

    enum BindError: Error {
        /// Another agent is already listening on this socket; this instance should exit quietly.
        case alreadyRunning
        case systemError(String)
    }

    init(path: String = Paths.socketPath, onVerb: @escaping @MainActor @Sendable (ControlVerb) -> Void) {
        self.path = path
        self.onVerb = onVerb
    }

    /// Binds and starts listening. Throws `.alreadyRunning` if a live agent already owns the socket,
    /// which is the mechanism that keeps two agents from ever coexisting.
    func start() throws {
        Paths.ensureStateDirectoryExists()
        try removeStaleSocketIfAny()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BindError.systemError("socket() failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: CChar.self)
            _ = path.withCString { cPath in
                strncpy(buffer.baseAddress, cPath, buffer.count - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw BindError.systemError("bind() failed: \(String(cString: strerror(errno)))")
        }

        // Socket file should only be reachable by the current user.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            throw BindError.systemError("listen() failed: \(String(cString: strerror(errno)))")
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "spacelight-control-socket"
        thread.start()
        acceptThread = thread
    }

    /// If a socket file already exists, checks whether it's live (another agent is running, in
    /// which case we bail out) or stale (the previous agent crashed without cleaning up, in which
    /// case we remove it and proceed).
    private func removeStaleSocketIfAny() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }

        let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { if probeFD >= 0 { close(probeFD) } }

        if probeFD >= 0 {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
                let buffer = rawPtr.bindMemory(to: CChar.self)
                _ = path.withCString { cPath in
                    strncpy(buffer.baseAddress, cPath, buffer.count - 1)
                }
            }
            let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(probeFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connectResult == 0 {
                // Something answered: a live agent already owns this socket.
                throw BindError.alreadyRunning
            }
        }

        // No one answered (ECONNREFUSED or similar): the file is a stale leftover from a crash.
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                // listenFD was closed out from under us (shutdown), stop looping.
                if errno == EBADF { return }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = read(clientFD, &buffer, buffer.count)
        guard n > 0 else { return }
        let raw = String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let verb = ControlVerb(rawValue: raw) else { return }
        Task { @MainActor [onVerb] in onVerb(verb) }
    }

    /// Closes the listening socket and removes the socket file. Call on clean shutdown (`quit`).
    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}
