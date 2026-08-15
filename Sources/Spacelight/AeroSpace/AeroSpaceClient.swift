import Foundation
import os

private let log = Logger(subsystem: "com.spacelight", category: "aerospace")

/// Talks to the `aerospace` CLI. Every call spawns a `Process`; on this machine a single
/// invocation measures at roughly 35ms, so all of this happens off the main actor and behind
/// `StateStore`'s cache rather than in the press-to-visible path.
actor AeroSpaceClient {
    struct Snapshot {
        var workspaces: [SwitcherItem]
        var windows: [SwitcherItem]
    }

    enum ClientError: Error {
        case executableNotFound
        case processFailed(status: Int32, stderr: String)
    }

    private static let workspaceFormat =
        "%{workspace}%{tab}%{workspace-is-focused}%{tab}%{workspace-is-visible}%{tab}%{monitor-id}%{tab}%{monitor-appkit-nsscreen-screens-id}"
    private static let windowFormat =
        "%{window-id}%{tab}%{app-name}%{tab}%{window-title}%{tab}%{workspace}%{tab}%{app-bundle-path}%{tab}%{monitor-id}"

    /// Resolved once and reused for every invocation, so later calls skip the PATH search.
    private var resolvedExecutablePath: String?

    /// Checked first because it's where Homebrew puts it on Apple silicon, which is what this
    /// project targets; falls back to a PATH search for other setups (Intel Homebrew, MacPorts, etc).
    private static let commonPaths = [
        "/opt/homebrew/bin/aerospace",
        "/usr/local/bin/aerospace",
    ]

    private func executablePath() throws -> String {
        if let resolvedExecutablePath { return resolvedExecutablePath }

        for candidate in Self.commonPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            resolvedExecutablePath = candidate
            return candidate
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let candidate = "\(directory)/aerospace"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    resolvedExecutablePath = candidate
                    return candidate
                }
            }
        }

        throw ClientError.executableNotFound
    }

    /// Runs both list queries concurrently and returns the parsed result.
    /// `--empty no` excludes workspaces with no windows in them: an empty workspace has nothing
    /// useful to switch to via this list (the numbered/named `aerospace workspace <n>` bindings in
    /// `~/.aerospace.toml` already cover "go create/visit an empty workspace").
    func snapshot() async throws -> Snapshot {
        async let workspacesOutput = run(["list-workspaces", "--monitor", "all", "--empty", "no", "--format", Self.workspaceFormat])
        async let windowsOutput = run(["list-windows", "--all", "--format", Self.windowFormat])
        let (workspacesText, windowsText) = try await (workspacesOutput, windowsOutput)
        return Snapshot(
            workspaces: SnapshotParser.parseWorkspaces(workspacesText),
            windows: SnapshotParser.parseWindows(windowsText)
        )
    }

    func focusWorkspace(_ name: String) async {
        do {
            _ = try await run(["workspace", name])
        } catch {
            log.error("focusWorkspace(\(name, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
    }

    func focusWindow(id: Int) async {
        do {
            _ = try await run(["focus", "--window-id", String(id)])
        } catch {
            log.error("focusWindow(\(id)) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Resolves the executable path once, for callers (like `EventSubscriber`) that need to spawn
    /// their own long-lived `aerospace` process rather than a one-shot `run`.
    func resolvedPath() throws -> String {
        try executablePath()
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        let path = try executablePath()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: String(decoding: stdoutData, as: UTF8.self))
                } else {
                    let stderrText = String(decoding: stderrData, as: UTF8.self)
                    continuation.resume(throwing: ClientError.processFailed(
                        status: proc.terminationStatus,
                        stderr: stderrText
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
