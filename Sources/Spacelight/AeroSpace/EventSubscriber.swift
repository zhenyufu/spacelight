import Foundation
import os

private let log = Logger(subsystem: "com.spacelight", category: "event-subscriber")

/// Keeps one long-lived `aerospace subscribe --all` process running for the life of the agent and
/// calls `onRelevantEvent` (debounced) whenever something happens that could make the cached
/// snapshot stale. This is what keeps `StateStore` warm without polling:
/// the only wakeups are real AeroSpace events, never a timer.
///
/// `subscribe --all` emits `focus-changed`, `focused-workspace-changed`,
/// `focused-monitor-changed`, and `mode-changed`, but notably *not* window created/destroyed
/// events, so every event here is treated as a hint to re-snapshot rather than a complete diff.
@MainActor
final class EventSubscriber {
    /// Debounce window: several of these events tend to arrive in a tight burst around a single
    /// user action (e.g. switching workspace fires both focus-changed and
    /// focused-workspace-changed), so batching them avoids redundant snapshots.
    private static let debounceInterval: Duration = .milliseconds(150)
    /// If the subscribe process dies unexpectedly (e.g. AeroSpace itself restarts), retry after
    /// this delay rather than silently letting the cache go stale forever.
    private static let respawnDelay: Duration = .seconds(2)

    private let onRelevantEvent: () -> Void
    private var process: Process?
    private var readTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isStopped = false

    init(onRelevantEvent: @escaping () -> Void) {
        self.onRelevantEvent = onRelevantEvent
    }

    func start(executablePath: String) {
        isStopped = false
        spawn(executablePath: executablePath)
    }

    func stop() {
        isStopped = true
        debounceTask?.cancel()
        readTask?.cancel()
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func spawn(executablePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["subscribe", "--all"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedExit(executablePath: executablePath)
            }
        }

        do {
            try process.run()
        } catch {
            log.error("failed to start aerospace subscribe: \(String(describing: error), privacy: .public)")
            return
        }

        self.process = process
        readTask = Task { [weak self] in
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    self?.handleLine(line)
                }
            } catch {
                // Stream ended abnormally (e.g. the process was killed mid-read); the
                // terminationHandler above is what drives respawning, this is just logging.
                log.debug("subscribe stream ended: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleUnexpectedExit(executablePath: String) {
        guard !isStopped else { return } // stop() already tore this down deliberately
        log.info("aerospace subscribe exited unexpectedly, respawning in \(Self.respawnDelay.description, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: Self.respawnDelay)
            guard let self, !self.isStopped else { return }
            self.spawn(executablePath: executablePath)
        }
    }

    /// Cheap substring check rather than a full JSON parse: every line from `subscribe --all` is
    /// one of the four known event types, and the caller treats all of them identically (as a
    /// hint to refresh), so there's nothing a full parse would add here.
    private func handleLine(_ line: String) {
        guard line.contains("\"_event\"") else { return }
        scheduleDebouncedRefresh()
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            self?.onRelevantEvent()
        }
    }
}
