// Which program is in the foreground of a tab, asked of the kernel.
//
// # Why not the OSC title
//
// The obvious source is the title the program sets with OSC 0/2, and it is the
// wrong one, for three separate reasons that each break it on their own:
//
//  - **It only arrives if something sends it.** On macOS the title comes from
//    the user's prompt — `precmd` in a zsh theme — so it depends on which
//    theme is installed, and a plain shell sends nothing at all.
//  - **It means different things to different programs.** One sends the file
//    it has open, another the host, another its own name.
//  - **It is not cleared on exit.** A program that sets a title and dies
//    leaves the tab wearing that name for ever. There is no event for "that
//    title is stale now", so the tab is simply wrong until it is closed.
//
// `tcgetpgrp` has none of those properties. It is exactly `btop` while btop is
// running and exactly `zsh` the moment it is not, it needs no cooperation from
// the shell, and it cannot go stale — it is read fresh every time.
//
// The OSC title is still accepted, as a layer *above* this one, and expires
// when the foreground process changes. See `SessionName`.
//
// # Cost
//
// Two syscalls per tab per poll: `tcgetpgrp` on the master PTY descriptor, and
// `proc_name` on the pid that comes back. Both read a struct the kernel
// already has; neither allocates, forks, or touches the filesystem. The poll
// runs at 1 Hz — see `TerminalSession.foregroundPollInterval` for why that
// number.

import Darwin
import Foundation

enum ForegroundProcess {
    /// The name of the process group in the foreground of this PTY, or `nil`.
    ///
    /// `nil` covers every failure the same way, because every caller does: the
    /// process exited, the descriptor is closed, the kernel declined. A tab
    /// whose foreground cannot be read keeps whatever name it had rather than
    /// being renamed to a guess.
    ///
    /// The descriptor is the **master** side, which the app holds. `tcgetpgrp`
    /// on it reports the foreground process group of the terminal, which is
    /// the state the slave side shares — the same value `ps` shows in its TPGID
    /// column.
    static func name(ofPTY descriptor: Int32) -> String? {
        guard descriptor >= 0 else { return nil }
        let group = tcgetpgrp(descriptor)
        // -1 is the error return, and 0 is a terminal with no foreground group
        // at all — a shell that has just exited, most often.
        guard group > 0 else { return nil }
        return name(ofProcess: group)
    }

    /// The executable name of `pid`.
    ///
    /// The pid asked for is a process **group** id, and that is correct rather
    /// than convenient: a foreground process group is led by the process that
    /// created it, and the leader's pid is the group id. `btop` run from the
    /// shell is its own group leader; a pipeline is led by its first command,
    /// which is the one worth naming.
    static func name(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        // `proc_name` writes at most `MAXCOMLEN * 2 + 1`; the buffer is
        // deliberately larger than that so a future kernel cannot truncate
        // into an unterminated string.
        var buffer = [CChar](repeating: 0, count: 256)
        let written = proc_name(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
