// Tests for the wire projection.
//
// This file exists because of one specific property of the sparse patch: it is
// the only place in the app where getting the decode wrong does **not** produce
// a crash. It produces a sidebar card showing a value the session no longer has,
// or an em dash where a value was — both of which look like a daemon bug, or
// like nothing at all, and neither of which points at this file. Everything else
// in the app fails loudly. This fails quietly, so it gets tests.
//
// The rest of the cases here are the ones `docs/PROTOCOL.md` states as rules
// rather than as shapes: unknown `type` is ignored, unknown `v` is dropped,
// unknown is `null` and never `""`.
//
// swift-testing rather than XCTest: better failure messages, parameterized
// cases, and no class-per-suite ceremony.
//
// **These need Xcode to run.** Neither `Testing` nor `XCTest` ships in a
// Command Line Tools install — `swift test` there fails with "no such module".
// `swift build` and `scripts/package.sh` deliberately do not need Xcode, and
// this is the one place that breaks the symmetry: on a CLT-only machine the
// tests are compiled and run by CI, not locally. That is a real gap, recorded
// here rather than papered over.

import Foundation
import Testing

@testable import AITerm

@Suite("Sparse patch")
struct SparsePatchTests {
    /// The three-way distinction, stated as the protocol states it: absent means
    /// *unchanged*, explicit `null` means *became unknown*, a value means a
    /// value. Two of those three collapse into `nil` under a naive decode, and
    /// the collapse is invisible until a card is wrong on screen.
    @Test func absentNullAndValueAreThreeDifferentOutcomes() throws {
        let line = Data("""
        {"type":"session_updated","v":1,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "title":null,"cwd":"/repo"}
        """.utf8)

        guard case .success(.sessionUpdated(let patch)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a session_updated")
            return
        }

        #expect(patch.title == .unknown, "an explicit null means it became unknown")
        #expect(patch.cwd == .value("/repo"))
        #expect(patch.model == .unchanged, "an absent field must not be readable as null")
        #expect(patch.gitBranch == .unchanged)
    }

    /// The failure this file exists to prevent, written as the app experiences
    /// it: applying a patch to what we already knew.
    @Test func applyingAPatchKeepsAbsentFieldsAndClearsNulledOnes() {
        let existing = "claude-opus-5"

        #expect(
            Patch<String>.unchanged.applied(to: existing) == existing,
            "an absent field must leave the old value alone"
        )
        #expect(
            Patch<String>.unknown.applied(to: existing) == nil,
            "an explicit null must clear the old value, not preserve it"
        )
        #expect(Patch<String>.value("claude-sonnet-5").applied(to: existing) == "claude-sonnet-5")
    }

    /// Compaction is the case the four token fields exist to survive: occupancy
    /// falls while the cumulative counters keep climbing. A decoder that treated
    /// the pairs as synonyms would produce a plausible, wrong number.
    @Test func theFourTokenFieldsDecodeIndependently() throws {
        let line = Data("""
        {"type":"session_updated","v":1,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "context_window_used_tokens":12000,"context_window_size_tokens":200000,\
        "cumulative_input_tokens":840000,"cumulative_output_tokens":31000}
        """.utf8)

        guard case .success(.sessionUpdated(let patch)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a session_updated")
            return
        }

        #expect(patch.contextWindowUsedTokens == .value(12_000))
        #expect(patch.contextWindowSizeTokens == .value(200_000))
        #expect(patch.cumulativeInputTokens == .value(840_000))
        #expect(patch.cumulativeOutputTokens == .value(31_000))
    }

    /// A zero is a reading, not an absence. The registry goes out of its way
    /// never to send a fabricated zero, so the decoder must not turn a real one
    /// into "unchanged".
    @Test func zeroIsAValueAndNotAnAbsence() throws {
        let line = Data("""
        {"type":"session_updated","v":1,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "context_window_used_tokens":0}
        """.utf8)

        guard case .success(.sessionUpdated(let patch)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a session_updated")
            return
        }
        #expect(patch.contextWindowUsedTokens == .value(0))
    }
}

@Suite("Inbound decoding")
struct InboundDecodingTests {
    /// Ignoring an unknown `type` is what lets the daemon ship a message before
    /// the app knows about it. It is a feature, and it has to stay one.
    @Test func anUnknownTypeIsIgnoredRatherThanTreatedAsCorrupt() {
        let line = Data(#"{"type":"invented_next_version","v":1,"ts":"2026-07-31T21:00:00Z"}"#.utf8)
        guard case .failure(.unknownType(let name)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected unknownType")
            return
        }
        #expect(name == "invented_next_version")
    }

    /// An unknown `v` is *not* the same tolerance. The fields we recognize may
    /// no longer mean what we think, so the line is dropped and the status is
    /// raised — silently accepting it is how a client renders a lie.
    @Test func anUnknownVersionIsDroppedEvenWhenTheRestParses() {
        let line = Data("""
        {"type":"session_registered","v":99,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "tab_id":null,"agent":"claude-code","cwd":null,"title":null,"model":null,\
        "started_at":"2026-07-31T21:00:00Z"}
        """.utf8)
        guard case .failure(.unsupportedVersion(let v)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected unsupportedVersion")
            return
        }
        #expect(v == 99)
    }

    /// Unknown *fields* are ignored, unlike unknown versions. Same document,
    /// opposite rule, and the difference is the whole forward-compatibility
    /// story.
    @Test func unknownFieldsAreIgnored() throws {
        let line = Data("""
        {"type":"session_registered","v":1,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "tab_id":"tab-1","agent":"claude-code","cwd":"/repo","title":null,"model":null,\
        "started_at":"2026-07-31T21:00:00Z","field_from_a_later_version":42}
        """.utf8)

        guard case .success(.sessionRegistered(let session)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a session_registered")
            return
        }
        #expect(session.sessionID == "s1")
        #expect(session.tabID == "tab-1")
    }

    /// `null` renders as *unknown*; `""` renders as an empty path, which reads
    /// as "the session is at the root". The daemon has a test for this on its
    /// side; the client needs one too, because the fabrication can be introduced
    /// at either end.
    @Test func anUnknownCwdDecodesAsNilAndNotAsAnEmptyString() throws {
        let line = Data("""
        {"type":"session_registered","v":1,"ts":"2026-07-31T21:00:00Z","session_id":"s1",\
        "tab_id":null,"agent":"unknown","cwd":null,"title":null,"model":null,\
        "started_at":"2026-07-31T21:00:00Z"}
        """.utf8)

        guard case .success(.sessionRegistered(let session)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a session_registered")
            return
        }
        #expect(session.cwd == nil)
        #expect(session.tabID == nil, "a session bound to no tab is supported, not an error")
        #expect(session.agent == "unknown", "`unknown` is an enumerated agent, not a fallback")
    }

    /// `decision` is `null` for every origin but `app`. When the human answered
    /// in the terminal we genuinely do not know what they chose, and the card
    /// must not invent an outcome.
    @Test func aTuiResolutionCarriesNoDecision() throws {
        let line = Data("""
        {"type":"hitl_resolved","v":1,"ts":"2026-07-31T21:00:00Z","hitl_id":"h1",\
        "session_id":"s1","origin":"tui","decision":null}
        """.utf8)

        guard case .success(.hitlResolved(let resolved)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a hitl_resolved")
            return
        }
        #expect(resolved.origin == "tui")
        #expect(resolved.decision == nil)
    }

    /// `permission_suggestions` is passed through untouched because its real
    /// shape contradicts the documentation. This asserts we *carry* it without
    /// asserting anything about what is inside.
    @Test func permissionSuggestionsSurviveAsOpaqueJSON() throws {
        let line = Data("""
        {"type":"hitl_pending","v":1,"ts":"2026-07-31T21:00:00Z","hitl_id":"h1",\
        "session_id":"s1","tab_id":"tab-1","tool_name":"Bash",\
        "tool_input":{"command":"rm -rf build/"},\
        "permission_suggestions":[{"type":"addRules","behavior":"allow"}],\
        "expires_at":"2026-07-31T21:05:00Z"}
        """.utf8)

        guard case .success(.hitlPending(let pending)) = DaemonMessageDecoder.decode(line: line) else {
            Issue.record("expected a hitl_pending")
            return
        }
        #expect(pending.toolName == "Bash")
        guard case .array(let suggestions) = pending.permissionSuggestions else {
            Issue.record("suggestions should survive as an array")
            return
        }
        #expect(suggestions.count == 1)
    }

    @Test(arguments: ["", "not json", "[1,2,3]", "{}", #"{"v":1}"#, "null"])
    func garbageIsRejectedRatherThanCrashing(garbage: String) {
        let result = DaemonMessageDecoder.decode(line: Data(garbage.utf8))
        guard case .failure = result else {
            Issue.record("expected \(garbage.debugDescription) to be rejected")
            return
        }
    }
}

@Suite("Outbound encoding")
struct OutboundEncodingTests {
    private func object(_ message: AppMessage) throws -> [String: Any] {
        let line = try #require(message.line())
        #expect(line.last == 0x0A, "JSON-lines: every message ends in a newline")
        let body = line.dropLast()
        #expect(!body.contains(0x0A), "JSON-lines: no message may embed a newline")
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// `cwd` is required-and-nullable, so an unknown one is an explicit `null`
    /// and never an omitted key. Omitting it would be a different statement in a
    /// protocol where absence has meaning.
    @Test func registerTabSendsAnExplicitNullForAnUnknownCwd() throws {
        let json = try object(.registerTab(tabID: "tab-1", cwd: nil))
        #expect(json["type"] as? String == "register_tab")
        #expect(json["v"] as? Int == 1)
        #expect(json.keys.contains("cwd"))
        #expect(json["cwd"] is NSNull)
    }

    @Test func closeTabCarriesOnlyTheEnvelopeAndTheTabID() throws {
        let json = try object(.closeTab(tabID: "tab-1"))
        #expect(json["type"] as? String == "close_tab")
        #expect(json["tab_id"] as? String == "tab-1")
        #expect(Set(json.keys) == ["type", "v", "ts", "tab_id"])
    }

    /// snake_case throughout, and the daemon does the camelCase translation at
    /// the hook boundary — so no client has to know the agent's wire format.
    @Test func resolveHitlIsSnakeCaseAndOmitsWhatWasNotSet() throws {
        let json = try object(.resolveHitl(
            hitlID: "h1",
            decision: .init(behavior: "deny", reason: "no", updatedInput: nil, updatedPermissions: nil)
        ))
        let decision = try #require(json["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["reason"] as? String == "no")
        #expect(!decision.keys.contains("updated_input"), "optional means omitted, not null")
        #expect(!decision.keys.contains("updated_permissions"))
    }

    @Test func requestSnapshotIsJustAnEnvelope() throws {
        let json = try object(.requestSnapshot)
        #expect(Set(json.keys) == ["type", "v", "ts"])
        #expect(json["type"] as? String == "request_snapshot")
    }

    /// `ts` is RFC 3339 with a timezone. Pinned to a fixed instant so the test
    /// does not depend on the clock or on the machine's timezone.
    @Test func timestampsAreRFC3339WithATimezone() {
        #expect(Protocol.timestamp(Date(timeIntervalSince1970: 1_700_000_000)) == "2023-11-14T22:13:20Z")
    }
}
