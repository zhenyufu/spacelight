import AppKit

// Spacelight is one binary with two personalities, chosen by how it's invoked:
//
//   spacelight             -> client: pings the resident agent, spawning one if needed, then exits
//   spacelight --agent     -> agent:  the long-lived process that owns the panel and the AeroSpace cache
//   spacelight <verb>      -> client: sends a specific verb (ping, show, hide, quit) instead of toggle
//
// This file only dispatches; the client and agent implementations live in Client/ and Agent/.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--agent" {
    // main.swift's top-level code runs synchronously on the process's main thread before any
    // concurrency machinery starts, so it is sound to assert main-actor isolation here once and
    // hand off into the (isolated) AppKit entry point.
    MainActor.assumeIsolated {
        runAgent()
    }
} else {
    let verb = arguments.first ?? "toggle"
    runClient(verb: verb)
}
