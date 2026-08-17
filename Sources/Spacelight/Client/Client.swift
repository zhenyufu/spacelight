import Darwin
import Foundation

/// The client side of a single press: connect to the agent's control socket, write one verb,
/// and exit. This is the one part of the system where process startup latency is user-visible
/// so it does the minimum possible amount of work: no JSON,
/// no argument parsing library, no retries beyond the one bounded wait for a freshly spawned agent.
func runClient(verb: String) {
    guard ControlVerb(rawValue: verb) != nil else {
        FileHandle.standardError.write(
            "spacelight: unknown verb '\(verb)' (expected toggle, show, hide, quit, or ping)\n"
                .data(using: .utf8)!
        )
        exit(64) // EX_USAGE
    }

    if sendVerb(verb, path: Paths.socketPath) {
        exit(0)
    }

    // No agent answered. Start one and give it a bounded window to come up before trying again.
    AgentLauncher.spawnAgent()

    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        if sendVerb(verb, path: Paths.socketPath) {
            exit(0)
        }
        usleep(10_000) // 10ms between retries
    }

    FileHandle.standardError.write("spacelight: agent did not start in time\n".data(using: .utf8)!)
    exit(1)
}

/// Connects to the unix socket at `path` and writes `verb` followed by a newline.
/// Returns false if the connect failed, which the caller treats as "no agent is running".
private func sendVerb(_ verb: String, path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

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
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return false }

    let payload = Array((verb + "\n").utf8)
    let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return written == payload.count
}
