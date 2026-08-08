// Watching one file, including the ways an editor stops it being that file.
//
// # Why this is not four lines
//
// The obvious version opens the file and hands the descriptor to a
// `DispatchSource`. It works, once, and then never again — because a descriptor
// names an **inode**, not a path, and vim's default save does not write into the
// inode it opened.
//
// With `backupcopy=auto`, which is the shipped default, `:w` writes a new file
// beside the old one and renames it over the top. The rename unlinks the inode
// the watcher is holding. The watcher is now the sole owner of a file with no
// name, watching for writes that will never come, on bytes nobody else can
// reach. The first save fires one `.rename` event and every save after it is
// silent. This is the classic failure of file watching on macOS and it is
// exactly the case this exists to survive.
//
// So there are two sources, and they cover different halves:
//
//  · **The directory.** Its inode is stable across any rename of its entries, so
//    it is what sees the atomic replace, and also what sees the file being
//    created for the first time. It cannot see a write *inside* an existing
//    file, because that does not change the directory.
//  · **The file.** It sees writes in place, which is what `backupcopy=yes`, a
//    `>>`, or `printf` into the path all do. It is re-armed whenever the
//    directory reports something, and whenever it reports its own death.
//
// Neither alone is enough, and both halves of that were measured by deleting
// one source and running the suite:
//
//  · Directory only — `a write in place is noticed` fails. Writing into an
//    existing file does not touch the directory, so nothing fires.
//  · File only, never re-armed — `a file replaced by rename` fails on the
//    *second* save, not the first. The first rename delivers one event and the
//    source then sits on the unlinked inode for ever. This is why the test
//    replaces the file three times: a test that saved once would pass against
//    the broken version.
//
// # Why events are coalesced
//
// One save is not one event. A truncate, a write and a rename arrive
// separately, and reading between them yields a file that is empty or half
// written — which parses as an error, shows an error, and then un-shows it a
// few milliseconds later. The flicker is worse than the delay: it teaches the
// reader that saving sometimes breaks the theme.
//
// The delay is short enough to feel immediate and long enough to let a save
// finish. Nothing here is correctness-critical: a coalesce that fires too early
// costs one wrong parse that the next event corrects.

import Foundation

/// Calls back when a path's contents change, however they change.
///
/// The callback lands on the main queue, because everything that reacts to it
/// touches the interface.
final class FileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void

    /// All state is touched on this queue and nowhere else. The sources fire
    /// here and re-arm themselves from inside their own handlers, so anything
    /// reachable from both there and the initialiser has to have one owner.
    private let queue = DispatchQueue(label: "digital.opengateway.violeet.filewatcher")

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// How long to wait for a save to finish before reading. See the note above
    /// on why one save is several events.
    private static let settle: DispatchTimeInterval = .milliseconds(90)

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.onChange = onChange
        // Armed **before** the initialiser returns, not on a hop.
        //
        // Asynchronously was the first version, and it leaves a window in which
        // the file can change before anything is listening — the change is then
        // lost for good, because these sources report events and not state.
        // Caught by the suite rather than by reasoning: the end-to-end test
        // wrote to a theme immediately after opening it, passed alone, and
        // failed under the parallel run where the hop was scheduled later.
        //
        // `sync` on a queue that was created two lines ago and has nothing on
        // it costs two `open` calls. That is a fair price for the caller being
        // able to write to the file on the next line.
        queue.sync {
            armDirectory()
            armFile()
        }
    }

    deinit {
        // Cancelled rather than left to be collected: the cancel handler is what
        // closes the descriptor, and a watcher per theme edit that never closed
        // one would run the process out of them over a long session.
        fileSource?.cancel()
        directorySource?.cancel()
        pending?.cancel()
    }

    /// Stop, now, without waiting to be deallocated.
    func stop() {
        queue.async { [weak self] in
            self?.fileSource?.cancel()
            self?.fileSource = nil
            self?.directorySource?.cancel()
            self?.directorySource = nil
            self?.pending?.cancel()
            self?.pending = nil
        }
    }

    // MARK: - Arming

    private func armDirectory() {
        directorySource?.cancel()
        directorySource = nil

        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Something in the directory moved. If it was our file being
            // replaced, the file source is now holding an inode nobody can
            // reach, so it is re-armed unconditionally — checking first would
            // cost a `stat` to save an `open`.
            self.armFile()
            self.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil

        // Absent is not an error. A theme being created for the first time does
        // not exist yet, and the directory source above is what will notice it
        // arriving and call back here.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let current = self.fileSource else { return }
            let flags = current.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // The path may now point at a different inode — re-open it and
                // watch that one instead. Without this the watcher survives
                // exactly one save.
                self.armFile()
            }
            self.schedule()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    // MARK: - Coalescing

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let callback = self.onChange
            DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }
}
