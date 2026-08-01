// The About panel.
//
// # Why it is not `orderFrontStandardAboutPanel:`
//
// The standard panel shows the bundle's name, version and copyright, and there
// is no hook for the two things this one exists to carry: where the project
// lives, and *which build this is*. A version string alone does not identify a
// build here — `0.9.2-dev` has been cut a dozen times today — so a bug report
// that says "0.9.2" says almost nothing. The commit hash makes it exact.
//
// # Why it is allowed to steal focus, when the settings panel is not
//
// The settings panel is a panel precisely so it never takes key status from the
// terminal: you change a colour while an agent is mid-sentence, and a window
// that took the keyboard would silently stop the session receiving what you
// type. About has no such duty — you are not typing at a terminal while reading
// a licence. It is an ordinary window, it takes focus, and closing it hands the
// keyboard straight back to the terminal it interrupted.

import AppKit
import SwiftUI

@MainActor
enum AboutWindow {
    /// Held so a second ⌘-About brings the existing window forward rather than
    /// stacking a second copy behind the first.
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // Its own window, so it is outside the scene that ContentView sets
        // the type scale in. Injected here instead, from the same setting,
        // so the About box is not the one pane that ignores it.
        let view = AboutView(daemonStatus: state.daemon.status)
            .environment(\.appFont, AppFont(body: state.preferences.terminal.window.interfaceFontSize))
        let hosting = NSHostingView(rootView: view)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            // No resize and no minimise: it is a fixed card of text, and a
            // minimised About is a window you find in the Dock a week later
            // wondering what it was.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.title = "About aiterm"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        // Released by us, not by AppKit, or the reference above would outlive
        // the object it points at.
        panel.isReleasedWhenClosed = false
        panel.center()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                teardown()
                // The whole point of the panel being allowed to take focus is
                // that it gives it back. Without this the terminal is left
                // looking focused and silently is not — the failure mode this
                // app has already been bitten by once.
                state.focusTerminal()
            }
        }

        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func teardown() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
    }
}

// MARK: - Contents

private struct AboutView: View {
    let daemonStatus: DaemonClient.Status

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)

                Text("aiterm")
                    .appFont(.display, weight: .semibold)

                Text(BuildInfo.versionLine)
                    .appFont(.body, design: .monospaced)
                    .foregroundStyle(.secondary)
                    // Selectable, because the reason it is on screen is that
                    // somebody is about to paste it into an issue.
                    .textSelection(.enabled)

                Text("A native macOS terminal for running AI coding agents as tabs.")
                    .appFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)

            Divider().padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 7) {
                row("Author", value: "Gabriel Gripp")
                row("GitHub", link: "https://github.com/grippado", label: "github.com/grippado")
                row("LinkedIn", link: "https://linkedin.com/in/grippado", label: "linkedin.com/in/grippado")
                row(
                    "Repository",
                    link: "https://github.com/grippado/aiterm",
                    label: "github.com/grippado/aiterm"
                )
                row("License", value: "MIT")
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 18)

            // The diagnostic line. It costs one row and answers the first two
            // questions any report about this app raises: was the daemon there,
            // and were the two of you speaking the same protocol.
            HStack(spacing: 6) {
                Circle()
                    .fill(daemonStatus.indicatorColor)
                    .frame(width: 6, height: 6)
                Text("\(daemonStatus.shortLabel) · protocol v\(Protocol.version)")
                    .appFont(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: 380)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .appFont(.body)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value).appFont(.body)
            Spacer(minLength: 0)
        }
    }

    private func row(_ label: String, link: String, label linkLabel: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .appFont(.body)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            LinkText(url: link, label: linkLabel)
            Spacer(minLength: 0)
        }
    }
}

/// A link that looks like one and behaves like one.
///
/// Not SwiftUI's `Link`: this opens through `NSWorkspace`, which is what sends
/// it to the user's default browser rather than to whatever handler the app
/// process happens to inherit. The two details that make it read as a link —
/// the accent colour and the pointing-hand cursor — are worth the twenty lines,
/// because a URL rendered as plain text is a URL nobody clicks.
private struct LinkText: View {
    let url: String
    let label: String

    @State private var hovering = false

    var body: some View {
        Text(label)
            .appFont(.body)
            .foregroundStyle(Color.accentColor)
            .underline(hovering)
            .onHover { inside in hovering = inside }
            .pointingHand()
            .onTapGesture {
                guard let target = URL(string: url) else { return }
                NSWorkspace.shared.open(target)
            }
            .accessibilityAddTraits(.isLink)
            .help(url)
    }
}

// MARK: - Which build this is

enum BuildInfo {
    /// The marketing version, from the bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The commit this bundle was built from, injected by `scripts/package.sh`.
    ///
    /// `nil` for a `swift run` build, which has no bundle at all — and rendered
    /// as nothing rather than as a placeholder hash, because a fake commit in a
    /// bug report is worse than an absent one.
    static var commit: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "AITermGitCommit") as? String
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }

    static var versionLine: String {
        guard let commit else { return "version \(version)" }
        return "version \(version) · \(commit)"
    }
}
