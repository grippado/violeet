// What a tab's shell is born with.
//
// The environment is copied from the app so a login shell starts with a real
// `PATH`. That copy is also how state belonging to whatever launched violeet
// reaches every session violeet starts, which is a bug with teeth: measured on a
// running build, an violeet opened from inside a Claude Code session handed
// `CLAUDE_CODE_CHILD_SESSION=1` to every tab, and that flag turns transcript
// writing off. The transcript is where every number on a card comes from.
//
// The same copy carries a second, unrelated category — `NO_COLOR` and
// `FORCE_COLOR`, measured 2026-08-09 — covered by the second suite below.

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

/// The second thing the wholesale copy carried, found the same way and by the
/// same mechanism as the session markers above.
///
/// Measured 2026-08-09: the `Violeet` app at pid 43373 held `NO_COLOR=1` and
/// `FORCE_COLOR=0`, and both were still there in the tab's shell (43409) and in
/// the `claude` it started (52081). Every tab of that window was colourless.
/// The emulator was cleared of blame first: inside an affected tab,
/// `printf '\033[31mR\033[32mG\033[34mB\033[0m\n'; tput colors` printed in
/// colour and answered `256`.
///
/// These tests feed `environment(inheriting:)` a fabricated environment rather
/// than `setenv`-ing the test process, so nothing here depends on how the
/// machine running the suite was launched.
@Suite("Inherited colour preferences")
struct InheritedColourPreferenceTests {
    private func environment(inheriting inherited: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in TerminalSession.environment(
            tabID: "tab-1", socketPath: "/tmp/s", inheriting: inherited
        ) {
            guard let split = entry.firstIndex(of: "=") else { continue }
            out[String(entry[entry.startIndex..<split])] =
                String(entry[entry.index(after: split)...])
        }
        return out
    }

    /// The bug itself. A violeet opened from a shell that had these handed them
    /// to every tab, and the tab has no reason to honour a choice made about a
    /// different terminal.
    @Test func colour_preferences_from_the_launcher_do_not_reach_the_child() {
        let env = environment(inheriting: ["NO_COLOR": "1", "FORCE_COLOR": "0", "PATH": "/usr/bin"])
        #expect(env["NO_COLOR"] == nil)
        #expect(env["FORCE_COLOR"] == nil)
    }

    /// The other half of the acceptance criterion: stripping stays a named list.
    /// A fix that started deleting anything it did not recognise would be a
    /// worse bug than the one it replaced.
    @Test func a_variable_that_is_not_listed_is_still_passed_through() {
        let env = environment(inheriting: [
            "NO_COLOR": "1",
            "PATH": "/usr/bin",
            "EDITOR": "nvim",
            "CLAUDE_CONFIG_DIR": "/home/someone/.claude",
        ])
        #expect(env["EDITOR"] == "nvim")
        #expect(env["PATH"] == "/usr/bin")
        #expect(
            env["CLAUDE_CONFIG_DIR"] == "/home/someone/.claude",
            "configuration someone chose, not state that leaked in")
    }

    /// Adding a second category must not cost the first one. This is the
    /// regression guard for the transcript bug that `inheritedAgentState`
    /// exists for.
    @Test func the_session_markers_are_still_stripped_alongside_them() {
        var inherited = ["NO_COLOR": "1", "PATH": "/usr/bin"]
        for name in TerminalSession.inheritedAgentState {
            inherited[name] = "leaked"
        }
        let env = environment(inheriting: inherited)
        for name in TerminalSession.inheritedAgentState {
            // violeet writes its own two back with this tab's values.
            if name.hasPrefix("VIOLEET_") { continue }
            #expect(env[name] == nil, "\(name) belongs to another session and must not be inherited")
        }
        #expect(env["VIOLEET_TAB_ID"] == "tab-1")
    }

    /// The two lists are separate on purpose — one is session identity, the
    /// other is a user's output preference — and the strip loop reads only the
    /// union. If a future edit adds a name to one list and the loop stops
    /// covering it, this fails.
    @Test func the_strip_list_is_the_union_of_both_categories() {
        #expect(TerminalSession.inheritedPresentationPreference == ["NO_COLOR", "FORCE_COLOR"])
        #expect(TerminalSession.inheritedAgentState.isDisjoint(
            with: TerminalSession.inheritedPresentationPreference))
        #expect(TerminalSession.strippedFromInheritedEnvironment
            .isSuperset(of: TerminalSession.inheritedAgentState))
        #expect(TerminalSession.strippedFromInheritedEnvironment
            .isSuperset(of: TerminalSession.inheritedPresentationPreference))
    }
}
