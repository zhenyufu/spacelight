import Foundation

/// Filesystem locations Spacelight reads or writes.
/// Kept in one place so the client, agent, and tests never disagree on where the socket or config lives.
enum Paths {
    /// Directory that holds runtime state: the control socket and (later) logs.
    /// `~/.local/state` follows the XDG convention for state that should survive a reboot but isn't user config.
    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/spacelight", isDirectory: true)
    }

    /// The unix domain socket the agent listens on and the client connects to.
    static var socketPath: String {
        stateDirectory.appendingPathComponent("agent.sock").path
    }

    /// Directory for user configuration.
    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spacelight", isDirectory: true)
    }

    static var configPath: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Creates `stateDirectory` if it doesn't exist yet, mode 0700 since the socket only needs to be
    /// reachable by the current user.
    @discardableResult
    static func ensureStateDirectoryExists() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: stateDirectory.path) { return true }
        do {
            try fm.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}
