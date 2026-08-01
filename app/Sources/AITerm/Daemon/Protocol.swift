// The Swift projection of `docs/PROTOCOL.md`.
//
// The document is normative. Where this file and the document disagree, this
// file is the bug — the same rule `crates/aiterm-proto` states for the Rust
// side. Keep the two projections shaped alike so a human can diff them.
//
// Two properties of the protocol drive every decision here:
//
//  - **Unknown `type` is ignored, unknown `v` is dropped-and-logged.** Those are
//    different outcomes for different reasons: an unknown type is how a later
//    version adds a message without breaking us, an unknown `v` means we cannot
//    trust the fields we *do* recognize.
//  - **`session_updated` is a sparse patch.** Absent means *unchanged*, explicit
//    `null` means *became unknown*. That is three states, so it is decoded into
//    `Patch`, not into `T?`. Collapsing it would make "we learned nothing" and
//    "we learned it is unknown" indistinguishable, which is the one thing the
//    daemon takes care never to conflate.

import Foundation

enum Protocol {
    /// The `v` this client speaks. A message with a greater `v` is dropped.
    static let version = 1

    /// RFC 3339 with a timezone, seconds precision — what `ts` is on the wire.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

// MARK: - Sparse patch fields

/// One field of a sparse patch: absent, explicitly unknown, or a value.
///
/// The Rust side spells this `Option<Option<T>>`. Swift has no such spelling by
/// default — `T??` collapses on `decodeIfPresent` — so it gets a named type.
enum Patch<T: Decodable & Equatable>: Equatable {
    /// The field was not in the message. Keep whatever we had.
    case unchanged
    /// The field was present and `null`. It *became* unknown.
    case unknown
    case value(T)

    /// Decode from a keyed container, distinguishing all three cases.
    static func decode(from container: KeyedDecodingContainer<DynamicKey>, key: DynamicKey) -> Patch<T> {
        guard container.contains(key) else { return .unchanged }
        if (try? container.decodeNil(forKey: key)) == true { return .unknown }
        guard let value = try? container.decode(T.self, forKey: key) else {
            // A field of the wrong type is not a reason to drop the whole
            // patch: the protocol says receivers ignore what they cannot use.
            return .unchanged
        }
        return .value(value)
    }

    /// Apply to an existing optional, which is what every consumer wants.
    func applied(to current: T?) -> T? {
        switch self {
        case .unchanged: return current
        case .unknown: return nil
        case .value(let v): return v
        }
    }
}

/// A `CodingKey` we can build from a string, so `Patch.decode` can name fields.
struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ name: String) { self.stringValue = name }
}

// MARK: - daemon -> app

struct SessionRegistered: Equatable {
    let sessionID: String
    /// `null` when the session could not be bound to a tab — an agent started
    /// outside aiterm. A real, supported state, not an error (ADR-003).
    let tabID: String?
    let agent: String
    let cwd: String?
    let title: String?
    let model: String?
    let startedAt: String
}

struct SessionUpdated: Equatable {
    let sessionID: String
    /// `starting` | `idle` | `working` | `hitl`. Not a patch: the daemon either
    /// reports a state or says nothing about it.
    let state: String?
    let title: Patch<String>
    let model: Patch<String>
    let cwd: Patch<String>
    /// Where `title` came from: `cwd` | `prompt` | `ai_title` | `user`.
    let titleSource: Patch<String>
    let contextWindowUsedTokens: Patch<Int>
    let contextWindowSizeTokens: Patch<Int>
    let cumulativeInputTokens: Patch<Int>
    let cumulativeOutputTokens: Patch<Int>
    /// Prompt tokens served from, and written into, the cache.
    ///
    /// Separate from `cumulativeInputTokens` on the wire because the three are
    /// priced differently. Measured on real transcripts, cache reads are 99.5%
    /// of everything the prompt side consumed — `cumulativeInputTokens` alone
    /// was 628 against 121 million — so a card that shows only the first is not
    /// rounding, it is reporting a different quantity than the one the reader
    /// thinks they are looking at.
    let cumulativeCacheReadTokens: Patch<Int>
    let cumulativeCacheCreationTokens: Patch<Int>
    /// `true` when the cumulative pair counts only part of the session.
    ///
    /// The daemon starts reading a transcript from its end, so a session
    /// already running when the daemon started contributes nothing before that
    /// moment. The number that results is not approximately right — it is wrong
    /// by an unknown amount and looks exactly like a correct small number. The
    /// card renders `~8k` when this is set, and that tilde is the only thing
    /// standing between the user and a total they would otherwise trust.
    let cumulativeTokensPartial: Patch<Bool>
    /// The account's subscription limits, from Claude Code's status line
    /// payload — a channel the transcript does not have. Flat rather than
    /// nested so a sparse patch can move one of them without resending the
    /// rest.
    let fiveHourLimitUsedPercent: Patch<Double>
    let fiveHourLimitResetsAt: Patch<String>
    let sevenDayLimitUsedPercent: Patch<Double>
    let sevenDayLimitResetsAt: Patch<String>
    /// Where a session aiterm did not start is actually running: the terminal
    /// application, and the tty inside it. Absent for a session in a tab, which
    /// needs no "where" — the tab is the answer.
    let originApp: Patch<String>
    let originTTY: Patch<String>
    let gitBranch: Patch<String>
    let lastAction: Patch<String>
    let lastEventAt: Patch<String>
    let tabID: Patch<String>

    /// Everything absent unless named.
    ///
    /// Written out rather than left to the memberwise default because absent is
    /// the protocol's own default — a field nobody mentions is one the daemon
    /// said nothing about. It also means adding a field to the protocol does
    /// not break every construction site: the test suite went several rounds
    /// without compiling for exactly that reason, and a suite that cannot build
    /// is a suite that is not testing anything.
    init(
        sessionID: String,
        state: String? = nil,
        title: Patch<String> = .unchanged,
        model: Patch<String> = .unchanged,
        cwd: Patch<String> = .unchanged,
        titleSource: Patch<String> = .unchanged,
        contextWindowUsedTokens: Patch<Int> = .unchanged,
        contextWindowSizeTokens: Patch<Int> = .unchanged,
        cumulativeInputTokens: Patch<Int> = .unchanged,
        cumulativeOutputTokens: Patch<Int> = .unchanged,
        cumulativeCacheReadTokens: Patch<Int> = .unchanged,
        cumulativeCacheCreationTokens: Patch<Int> = .unchanged,
        cumulativeTokensPartial: Patch<Bool> = .unchanged,
        fiveHourLimitUsedPercent: Patch<Double> = .unchanged,
        fiveHourLimitResetsAt: Patch<String> = .unchanged,
        sevenDayLimitUsedPercent: Patch<Double> = .unchanged,
        sevenDayLimitResetsAt: Patch<String> = .unchanged,
        originApp: Patch<String> = .unchanged,
        originTTY: Patch<String> = .unchanged,
        gitBranch: Patch<String> = .unchanged,
        lastAction: Patch<String> = .unchanged,
        lastEventAt: Patch<String> = .unchanged,
        tabID: Patch<String> = .unchanged
    ) {
        self.sessionID = sessionID
        self.state = state
        self.title = title
        self.model = model
        self.cwd = cwd
        self.titleSource = titleSource
        self.contextWindowUsedTokens = contextWindowUsedTokens
        self.contextWindowSizeTokens = contextWindowSizeTokens
        self.cumulativeInputTokens = cumulativeInputTokens
        self.cumulativeOutputTokens = cumulativeOutputTokens
        self.cumulativeCacheReadTokens = cumulativeCacheReadTokens
        self.cumulativeCacheCreationTokens = cumulativeCacheCreationTokens
        self.cumulativeTokensPartial = cumulativeTokensPartial
        self.fiveHourLimitUsedPercent = fiveHourLimitUsedPercent
        self.fiveHourLimitResetsAt = fiveHourLimitResetsAt
        self.sevenDayLimitUsedPercent = sevenDayLimitUsedPercent
        self.sevenDayLimitResetsAt = sevenDayLimitResetsAt
        self.originApp = originApp
        self.originTTY = originTTY
        self.gitBranch = gitBranch
        self.lastAction = lastAction
        self.lastEventAt = lastEventAt
        self.tabID = tabID
    }
}

struct HitlPending: Equatable {
    let hitlID: String
    let sessionID: String
    let tabID: String?
    let toolName: String
    /// Opaque. The app renders it; it must not assume a schema per tool.
    let toolInput: JSONValue
    /// Verbatim passthrough — the documented shape is already wrong in
    /// v2.1.220, so nothing here parses it.
    let permissionSuggestions: JSONValue
    let expiresAt: String
}

struct HitlResolved: Equatable {
    let hitlID: String
    let sessionID: String
    /// `app` | `tui` | `timeout` | `daemon_error`
    let origin: String
    /// `allow` | `deny` when `origin` is `app`; `null` otherwise.
    let decision: String?
}

struct SessionEnded: Equatable {
    let sessionID: String
    let tabID: String?
    /// `session_end_hook` | `process_exited` | `tab_closed` | `daemon_shutdown`
    let reason: String
}

/// Everything the daemon can say to us.
enum DaemonMessage: Equatable {
    case sessionRegistered(SessionRegistered)
    case sessionUpdated(SessionUpdated)
    case hitlPending(HitlPending)
    case hitlResolved(HitlResolved)
    case sessionEnded(SessionEnded)
}

/// Why a received line produced no message.
///
/// Mirrors the Rust `Rejected`. Every one of these is logged and dropped; the
/// protocol has no error reply in either direction and inventing one would be a
/// unilateral extension.
enum Rejected: Error, Equatable {
    /// Not JSON, or not an object.
    case malformed(String)
    /// Well-formed but `v` is newer than we understand.
    case unsupportedVersion(Int)
    /// A `type` we do not know. Ignored on purpose — that is what lets a later
    /// protocol version add messages without breaking this build.
    case unknownType(String)
}

enum DaemonMessageDecoder {
    /// Parse one inbound line.
    ///
    /// Deliberately total: every failure is a `Rejected`, never a throw the
    /// caller has to translate and never a crash. A daemon that starts emitting
    /// garbage must not be able to take the terminal down with it.
    static func decode(line: Data) -> Result<DaemonMessage, Rejected> {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return .failure(.malformed("top-level value is not an object"))
            }
            object = parsed
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }

        // Version first: an unknown `v` is dropped even when the rest parses,
        // because the fields we recognize may no longer mean what we think.
        if let v = object["v"] as? Int, v > Protocol.version {
            return .failure(.unsupportedVersion(v))
        }

        guard let type = object["type"] as? String else {
            return .failure(.malformed("missing `type`"))
        }

        let container: KeyedDecodingContainer<DynamicKey>
        do {
            container = try JSONDecoder().decode(RawContainer.self, from: line).container
        } catch {
            return .failure(.malformed(error.localizedDescription))
        }

        func string(_ key: String) -> String? {
            try? container.decode(String.self, forKey: DynamicKey(key))
        }
        func optionalString(_ key: String) -> String? {
            guard container.contains(DynamicKey(key)) else { return nil }
            return try? container.decode(String.self, forKey: DynamicKey(key))
        }
        func json(_ key: String) -> JSONValue {
            (try? container.decode(JSONValue.self, forKey: DynamicKey(key))) ?? .null
        }

        switch type {
        case "session_registered":
            guard let sessionID = string("session_id"),
                  let agent = string("agent"),
                  let startedAt = string("started_at")
            else { return .failure(.malformed("session_registered is missing a required field")) }
            return .success(.sessionRegistered(SessionRegistered(
                sessionID: sessionID,
                tabID: optionalString("tab_id"),
                agent: agent,
                cwd: optionalString("cwd"),
                title: optionalString("title"),
                model: optionalString("model"),
                startedAt: startedAt
            )))

        case "session_updated":
            guard let sessionID = string("session_id") else {
                return .failure(.malformed("session_updated is missing session_id"))
            }
            return .success(.sessionUpdated(SessionUpdated(
                sessionID: sessionID,
                state: optionalString("state"),
                title: Patch.decode(from: container, key: DynamicKey("title")),
                model: Patch.decode(from: container, key: DynamicKey("model")),
                cwd: Patch.decode(from: container, key: DynamicKey("cwd")),
                titleSource: Patch.decode(from: container, key: DynamicKey("title_source")),
                contextWindowUsedTokens: Patch.decode(from: container, key: DynamicKey("context_window_used_tokens")),
                contextWindowSizeTokens: Patch.decode(from: container, key: DynamicKey("context_window_size_tokens")),
                cumulativeInputTokens: Patch.decode(from: container, key: DynamicKey("cumulative_input_tokens")),
                cumulativeOutputTokens: Patch.decode(from: container, key: DynamicKey("cumulative_output_tokens")),
                cumulativeCacheReadTokens: Patch.decode(from: container, key: DynamicKey("cumulative_cache_read_tokens")),
                cumulativeCacheCreationTokens: Patch.decode(from: container, key: DynamicKey("cumulative_cache_creation_tokens")),
                cumulativeTokensPartial: Patch.decode(from: container, key: DynamicKey("cumulative_tokens_partial")),
                fiveHourLimitUsedPercent: Patch.decode(from: container, key: DynamicKey("five_hour_limit_used_percent")),
                fiveHourLimitResetsAt: Patch.decode(from: container, key: DynamicKey("five_hour_limit_resets_at")),
                sevenDayLimitUsedPercent: Patch.decode(from: container, key: DynamicKey("seven_day_limit_used_percent")),
                sevenDayLimitResetsAt: Patch.decode(from: container, key: DynamicKey("seven_day_limit_resets_at")),
                originApp: Patch.decode(from: container, key: DynamicKey("origin_app")),
                originTTY: Patch.decode(from: container, key: DynamicKey("origin_tty")),
                gitBranch: Patch.decode(from: container, key: DynamicKey("git_branch")),
                lastAction: Patch.decode(from: container, key: DynamicKey("last_action")),
                lastEventAt: Patch.decode(from: container, key: DynamicKey("last_event_at")),
                tabID: Patch.decode(from: container, key: DynamicKey("tab_id"))
            )))

        case "hitl_pending":
            guard let hitlID = string("hitl_id"),
                  let sessionID = string("session_id"),
                  let toolName = string("tool_name"),
                  let expiresAt = string("expires_at")
            else { return .failure(.malformed("hitl_pending is missing a required field")) }
            return .success(.hitlPending(HitlPending(
                hitlID: hitlID,
                sessionID: sessionID,
                tabID: optionalString("tab_id"),
                toolName: toolName,
                toolInput: json("tool_input"),
                permissionSuggestions: json("permission_suggestions"),
                expiresAt: expiresAt
            )))

        case "hitl_resolved":
            guard let hitlID = string("hitl_id"),
                  let sessionID = string("session_id"),
                  let origin = string("origin")
            else { return .failure(.malformed("hitl_resolved is missing a required field")) }
            return .success(.hitlResolved(HitlResolved(
                hitlID: hitlID,
                sessionID: sessionID,
                origin: origin,
                decision: optionalString("decision")
            )))

        case "session_ended":
            guard let sessionID = string("session_id"), let reason = string("reason") else {
                return .failure(.malformed("session_ended is missing a required field"))
            }
            return .success(.sessionEnded(SessionEnded(
                sessionID: sessionID,
                tabID: optionalString("tab_id"),
                reason: reason
            )))

        default:
            return .failure(.unknownType(type))
        }
    }
}

/// Holds a decoding container open so the field helpers above can reach it.
private struct RawContainer: Decodable {
    let container: KeyedDecodingContainer<DynamicKey>
    init(from decoder: Decoder) throws {
        container = try decoder.container(keyedBy: DynamicKey.self)
    }
}

// MARK: - app -> daemon

/// Everything this client can say to the daemon.
///
/// Encoded here rather than through `Codable` synthesis because the envelope
/// (`type`, `v`, `ts`) is flattened onto the same object as the payload, and
/// hand-writing three keys is cheaper than teaching `Encodable` to do it.
enum AppMessage {
    case registerTab(tabID: String, cwd: String?)
    case closeTab(tabID: String)
    case requestSnapshot
    case renameSession(sessionID: String, title: String)
    /// Back to automatic naming. Separate from a rename with an empty title,
    /// which the daemon refuses on purpose — an empty name is a mistake, and
    /// unlocking is a decision.
    case releaseSessionTitle(sessionID: String)
    case resolveHitl(hitlID: String, decision: HitlDecision)

    struct HitlDecision {
        /// `allow` | `deny`
        let behavior: String
        var reason: String?
        var updatedInput: JSONValue?
        var updatedPermissions: JSONValue?
    }

    /// One JSON-lines line, terminator included, or `nil` if it somehow could
    /// not be serialized — a single bad message must not kill the connection.
    func line(now: Date = Date()) -> Data? {
        var object: [String: Any] = ["v": Protocol.version, "ts": Protocol.timestamp(now)]

        switch self {
        case .registerTab(let tabID, let cwd):
            object["type"] = "register_tab"
            object["tab_id"] = tabID
            // Required by the protocol and explicitly nullable: `null` is
            // "unknown", never `""`, which would render as an empty path.
            object["cwd"] = cwd ?? NSNull()

        case .closeTab(let tabID):
            object["type"] = "close_tab"
            object["tab_id"] = tabID

        case .requestSnapshot:
            object["type"] = "request_snapshot"

        case .renameSession(let sessionID, let title):
            object["type"] = "rename_session"
            object["session_id"] = sessionID
            object["title"] = title

        case .releaseSessionTitle(let sessionID):
            object["type"] = "release_session_title"
            object["session_id"] = sessionID

        case .resolveHitl(let hitlID, let decision):
            object["type"] = "resolve_hitl"
            object["hitl_id"] = hitlID
            var payload: [String: Any] = ["behavior": decision.behavior]
            if let reason = decision.reason { payload["reason"] = reason }
            if let input = decision.updatedInput { payload["updated_input"] = input.anyValue }
            if let perms = decision.updatedPermissions { payload["updated_permissions"] = perms.anyValue }
            object["decision"] = payload
        }

        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else { return nil }

        // JSON-lines: no pretty-printing, no embedded raw newlines. The
        // serializer above emits neither, so this is the only terminator.
        data.append(0x0A)
        return data
    }
}

// MARK: - Opaque JSON

/// A JSON value we carry but do not interpret.
///
/// `tool_input` and `permission_suggestions` are both declared opaque by the
/// protocol, and `permission_suggestions` emphatically so: its real shape
/// contradicts the official documentation, so anything that parses it is
/// betting on an undocumented shape.
indirect enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unrepresentable JSON")
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}
