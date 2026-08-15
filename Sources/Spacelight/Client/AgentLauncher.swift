import Darwin
import Foundation

/// Starts a detached `spacelight --agent` process from the client path.
/// Uses `Process` (not raw `posix_spawn`) for the small one-time cost of the initial launch;
/// this only runs on cold start or after a crash, so it is not on the steady-state critical path.
enum AgentLauncher {
    /// Resolves the path of the currently running binary via `_NSGetExecutablePath`, which is
    /// correct even when invoked through PATH lookup or a relative path, unlike `argv[0]`.
    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        let nulTerminatorIndex = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<nulTerminatorIndex], as: UTF8.self)
    }

    static func spawnAgent() {
        guard let executablePath = currentExecutablePath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--agent"]

        // Detach fully: no pipes, own process group, so the client exiting doesn't affect it
        // and the agent doesn't inherit a controlling terminal from whatever spawned the client.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
    }
}
