// Reading a child process's current working directory.
//
// The sidebar wants to show where each tab *is*, not where it started, and a
// shell's `cd` leaves no trace anywhere the app can see. Three ways to learn it,
// and only one of them works unconditionally:
//
//  - **OSC 7** is the well-behaved answer, and SwiftTerm reports it. But macOS
//    only emits it from `/etc/zshrc` when `TERM_PROGRAM` is `Apple_Terminal`,
//    so in this app no stock shell sends it. It is honoured when it arrives and
//    never depended on.
//  - **A shell integration** (a `precmd` hook in the user's rc files) is what a
//    mature terminal ships. It is also a per-shell surface and an edit to files
//    that are not ours, which ADR-003 already declined for tab binding.
//  - **`proc_pidinfo`** asks the kernel. No cooperation from the shell, works
//    for every shell, and costs one syscall per tab per poll.
//
// So: `proc_pidinfo`, polled, with OSC 7 accepted as a bonus when a configured
// shell does send it. Failure returns `nil` and the caller keeps the last known
// value rather than inventing one.

import Darwin
import Foundation

enum ProcessDirectory {
    /// The working directory of `pid`, or `nil` if it cannot be read.
    ///
    /// `nil` covers the ordinary cases — the process exited, or the kernel
    /// declined — as well as the odd ones. None of them are worth
    /// distinguishing: every caller does the same thing with the answer.
    static func current(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }

        let size = MemoryLayout<proc_vnodepathinfo>.size
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<proc_vnodepathinfo>.alignment
        )
        defer { buffer.deallocate() }

        let read = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, buffer, Int32(size))
        // A short read means the struct we were given is not the struct we
        // asked for. Reading it anyway would be reading uninitialized memory.
        guard read == Int32(size) else { return nil }

        var info = buffer.assumingMemoryBound(to: proc_vnodepathinfo.self).pointee
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            let value = String(cString: base)
            return value.isEmpty ? nil : value
        }
        return path
    }

    /// `/Users/you/www/personal/aiterm` shown as `~/www/personal/aiterm`.
    ///
    /// Display only. The path sent to the daemon is always absolute — a tilde
    /// is this machine's shorthand and means nothing on the wire.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
