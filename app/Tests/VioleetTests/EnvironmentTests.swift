// What a tab's shell is born with.
//
// The environment is copied from the app so a login shell starts with a real
// `PATH`. That copy is also how state belonging to whatever launched violeet
// reaches every session violeet starts, which is a bug with teeth: measured on a
// running build, an violeet opened from inside a Claude Code session handed
// `CLAUDE_CODE_CHILD_SESSION=1` to every tab, and that flag turns transcript
// writing off. The transcript is where every number on a card comes from.

import Foundation
import Testing

@testable import Violeet

@Suite("Child environment")
struct ChildEnvironmentTests {
    private func environment(tabID: String = "tab-1", socket: String = "/tmp/s") -> [String: String] {
        var out: [String: String] = [:]
        for entry in TerminalSession.environment(tabID: tabID, socketPath: socket) {
            guard let split = entry.firstIndex(of: "=") else { continue }
            out[String(entry[entry.startIndex..<split])] =
                String(entry[entry.index(after: split)...])
        }
        return out
    }

    /// The binding is the whole tab/session mechanism (ADR-003), and it has to
    /// be this tab's, whatever the app inherited.
    @Test func the_tab_id_is_this_tab_and_the_socket_is_ours() {
        let env = environment(tabID: "tab-abc", socket: "/tmp/daemon.sock")
        #expect(env["VIOLEET_TAB_ID"] == "tab-abc")
        #expect(env["VIOLEET_SOCKET"] == "/tmp/daemon.sock")
    }

    /// The failure this file exists for. Every one of these describes a session
    /// that is not the one being started.
    @Test func agent_session_state_does_not_reach_the_child() {
        let env = environment()
        for name in TerminalSession.inheritedAgentState {
            // The two violeet sets itself are in the list so an violeet launched
            // from an violeet tab cannot pass on the old tab's id; they are then
            // written back with this tab's values.
            if name.hasPrefix("VIOLEET_") { continue }
            #expect(env[name] == nil, "\(name) belongs to another session and must not be inherited")
        }
    }

    /// Specifically the one that cost telemetry, named on its own so a future
    /// edit to the set cannot quietly drop it.
    @Test func the_flag_that_turns_transcripts_off_is_stripped() {
        #expect(TerminalSession.inheritedAgentState.contains("CLAUDE_CODE_CHILD_SESSION"))
        #expect(environment()["CLAUDE_CODE_CHILD_SESSION"] == nil)
    }

    /// Stripping must not become a general purge. A login shell puts back
    /// anything the user configured, but `PATH` is exactly what the copy exists
    /// to preserve for anything else launched in the tab.
    @Test func the_things_a_terminal_needs_are_still_there() {
        let env = environment()
        #expect(env["PATH"] != nil)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM"] == "violeet")
        #expect(env["LANG"] != nil, "a non-UTF-8 locale fills the grid with replacement characters")
    }

    /// The list is names, not a prefix match. A prefix would also take a
    /// `CLAUDE_CONFIG_DIR` the user set on purpose, and this is meant to remove
    /// what leaked in, not what someone chose.
    @Test func stripping_is_by_name_and_not_by_prefix() {
        #expect(!TerminalSession.inheritedAgentState.contains("CLAUDE_CONFIG_DIR"))
        #expect(!TerminalSession.inheritedAgentState.contains("ANTHROPIC_API_KEY"))
    }
}
