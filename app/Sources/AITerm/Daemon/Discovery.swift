// `~/.aiterm/daemon.json` — the file clients read instead of guessing.
//
// The app only needs the socket path, and the protocol already fixes that at
// `~/.aiterm/daemon.sock`. Reading the file anyway buys two things the constant
// does not: the daemon's `protocol_version`, so a mismatch is a diagnosable
// state rather than a stream of dropped lines, and a socket path that can move
// without this build having to.
//
// Its absence is not an error. The daemon removes the file on a clean shutdown
// and may not have written it at all (it treats that failure as non-fatal), so
// "no discovery file" means "fall back to the default path", never "give up".

import Foundation

struct DaemonInfo: Decodable, Equatable {
    let pid: Int
    let socket: String
    let hookPort: Int
    let protocolVersion: Int
    let startedAt: String

    enum CodingKeys: String, CodingKey {
        case pid
        case socket
        case hookPort = "hook_port"
        case protocolVersion = "protocol_version"
        case startedAt = "started_at"
    }
}

enum Discovery {
    static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/.aiterm/daemon.sock`, the path the protocol fixes.
    static var defaultSocketPath: String {
        homeDirectory.appendingPathComponent(".aiterm/daemon.sock").path
    }

    static var discoveryFilePath: String {
        homeDirectory.appendingPathComponent(".aiterm/daemon.json").path
    }

    /// Read the discovery file, or `nil` when it is absent or unreadable.
    ///
    /// A half-written file cannot be observed: the daemon writes to a temporary
    /// name and renames, and rename within a directory is atomic on macOS.
    static func read() -> DaemonInfo? {
        guard let data = FileManager.default.contents(atPath: discoveryFilePath) else { return nil }
        return try? JSONDecoder().decode(DaemonInfo.self, from: data)
    }

    /// Where to connect: what the daemon published, else the default.
    static func socketPath() -> String {
        guard let info = read(), !info.socket.isEmpty else { return defaultSocketPath }
        return info.socket
    }
}
