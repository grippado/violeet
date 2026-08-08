// The precedence chain, level by level, and the one property that matters
// more than all of them: a name the user typed is never taken away.

import Foundation
import Testing

@testable import Violeet

// MARK: - One test per level

@Test("level 5: a tab that has told us nothing gets a generic name, not an empty one")
func fallbackNamesATabWithNothing() {
    let name = SessionName.resolve(NameInputs())
    #expect(name.text == SessionName.fallback)
    #expect(name.source == .fallback)
    #expect(!name.text.isEmpty)
}

@Test("level 4: the working directory names a tab with nothing else")
func directoryNamesATabWithNothingElse() {
    let name = SessionName.resolve(NameInputs(cwd: "/Users/grippado/www/personal/violeet"))
    #expect(name.text == "violeet")
    #expect(name.source == .directory)
}

@Test("level 3: the agent's title beats the directory")
func agentTitleBeatsTheDirectory() {
    let name = SessionName.resolve(
        NameInputs(
            agentTitle: "Corrigir o parser de transcript",
            agentTitleSource: "ai_title",
            cwd: "/Users/grippado/www/personal/violeet"
        )
    )
    #expect(name.text == "Corrigir o parser de transcript")
    #expect(name.source == .agent)
}

@Test("level 2: the foreground process beats the agent's title and the directory")
func foregroundProcessBeatsTheAgentTitle() {
    let name = SessionName.resolve(
        NameInputs(
            agentTitle: "Corrigir o parser",
            agentTitleSource: "ai_title",
            foregroundProcess: "btop",
            cwd: "/Users/grippado/www/personal/violeet"
        )
    )
    #expect(name.text == "btop")
    #expect(name.source == .process)
}

@Test("level 1: a name the user typed is the name")
func manualNameIsTheName() {
    let name = SessionName.resolve(NameInputs(manualName: "onda 2"))
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
    #expect(name.isLocked)
}

// MARK: - Level 1 against each of the other four

/// The bug this whole file exists to prevent, stated four times.
@Test("a manual name beats the foreground process")
func manualBeatsProcess() {
    let name = SessionName.resolve(
        NameInputs(manualName: "onda 2", foregroundProcess: "btop")
    )
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
}

@Test("a manual name beats the agent's title, including a later ai-title")
func manualBeatsAgentTitle() {
    let name = SessionName.resolve(
        NameInputs(
            manualName: "onda 2",
            agentTitle: "Implementar sistema de nomes",
            agentTitleSource: "ai_title"
        )
    )
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
}

@Test("a manual name beats the working directory")
func manualBeatsDirectory() {
    let name = SessionName.resolve(
        NameInputs(manualName: "onda 2", cwd: "/Users/grippado/www/personal/violeet")
    )
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
}

@Test("a manual name beats the fallback")
func manualBeatsFallback() {
    let name = SessionName.resolve(NameInputs(manualName: "onda 2"))
    #expect(name.text == "onda 2")
    #expect(name.text != SessionName.fallback)
}

@Test("a manual name beats all four at once — the state a real tab is actually in")
func manualBeatsEverythingTogether() {
    let name = SessionName.resolve(
        NameInputs(
            manualName: "onda 2",
            agentTitle: "Implementar sistema de nomes",
            agentTitleSource: "ai_title",
            foregroundProcess: "btop",
            oscTitle: "btop — worzix",
            oscProcess: "btop",
            cwd: "/Users/grippado/www/personal/violeet"
        )
    )
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
}

/// A rename made in a previous run comes back through the daemon rather than
/// through the app's own state, and must still win. Without this the sidebar
/// would show the restored name for one frame and then replace it with the
/// foreground process — the same "it came back on its own", one restart later.
@Test("a rename restored from the daemon still outranks everything")
func restoredUserTitleOutranksEverything() {
    let name = SessionName.resolve(
        NameInputs(
            agentTitle: "onda 2",
            agentTitleSource: "user",
            foregroundProcess: "btop",
            cwd: "/Users/grippado"
        )
    )
    #expect(name.text == "onda 2")
    #expect(name.source == .manual)
    #expect(name.isLocked)
}

/// Unlocking is the daemon dropping `title_source` back to a derived one. The
/// app must follow it down rather than keeping the name it was last shown.
@Test("after unlocking, the chain resumes from level 2")
func unlockingResumesTheChain() {
    let locked = NameInputs(
        agentTitle: "onda 2",
        agentTitleSource: "user",
        foregroundProcess: "btop",
        cwd: "/Users/grippado/www/personal/violeet"
    )
    var unlocked = locked
    unlocked.agentTitle = "Implementar sistema de nomes"
    unlocked.agentTitleSource = "ai_title"

    #expect(SessionName.resolve(locked).text == "onda 2")
    let after = SessionName.resolve(unlocked)
    #expect(after.text == "btop")
    #expect(after.source == .process)
    #expect(!after.isLocked)
}

// MARK: - Level 4: the home directory

/// The reported bug, as a test. `~`'s last component is the login name, so
/// every tab sitting in the home directory was called "grippado".
@Test("the home directory is ~ and never the login name")
func homeIsTilde() {
    let home = NSHomeDirectory()
    #expect(SessionName.directoryName(home) == "~")
    #expect(SessionName.directoryName(home + "/") == "~")
    #expect(SessionName.directoryName(home) != (home as NSString).lastPathComponent)

    let name = SessionName.resolve(NameInputs(cwd: home))
    #expect(name.text == "~")
    #expect(name.source == .directory)
}

@Test("a directory under home is named by its own last component")
func directoryUnderHomeKeepsItsName() {
    let home = NSHomeDirectory()
    #expect(SessionName.directoryName(home + "/Documents") == "Documents")
    #expect(SessionName.directoryName(home + "/www/personal/violeet") == "violeet")
}

@Test("a directory outside home is named the same way, and root is root")
func directoryOutsideHome() {
    #expect(SessionName.directoryName("/etc") == "etc")
    #expect(SessionName.directoryName("/usr/local/bin") == "bin")
    #expect(SessionName.directoryName("/") == "/")
    #expect(SessionName.directoryName("") == nil)
    #expect(SessionName.directoryName(nil) == nil)
}

/// Another user's home is not this user's home. The tilde rule is about
/// `$HOME` specifically, not about "any path two levels under /Users".
@Test("another account's home directory is not abbreviated")
func anotherHomeIsNotTilde() {
    #expect(SessionName.directoryName("/Users/someone-else") == "someone-else")
}

// MARK: - Level 2: which process names a tab

@Test("a shell in the foreground names nothing and falls through")
func shellsAreNotNames() {
    for shell in ["zsh", "bash", "fish", "sh", "-zsh", "ZSH"] {
        #expect(
            SessionName.usefulProcess(shell) == nil,
            "\(shell) is the absence of a running program, not the name of one"
        )
    }

    let name = SessionName.resolve(
        NameInputs(foregroundProcess: "-zsh", cwd: "/Users/grippado/www/personal/violeet")
    )
    #expect(name.text == "violeet")
    #expect(name.source == .directory)
}

@Test("a login shell's leading dash is not part of a program's name")
func loginDashIsStripped() {
    #expect(SessionName.usefulProcess("-vim") == "vim")
    #expect(SessionName.usefulProcess("vim") == "vim")
    #expect(SessionName.usefulProcess("  ") == nil)
    #expect(SessionName.usefulProcess(nil) == nil)
}

/// The sequence the user will actually perform: run btop, quit btop.
@Test("leaving a program returns the tab to the level below it")
func leavingAProgramReturnsTheName() {
    var input = NameInputs(
        agentTitle: "Corrigir o parser",
        agentTitleSource: "ai_title",
        foregroundProcess: "btop",
        cwd: "/Users/grippado/www/personal/violeet"
    )
    #expect(SessionName.resolve(input).text == "btop")

    input.foregroundProcess = "zsh"
    #expect(SessionName.resolve(input).text == "Corrigir o parser")
}

// MARK: - The OSC layer

@Test("an OSC title is used only while the process that set it is in the foreground")
func oscTitleExpiresWithItsProcess() {
    var input = NameInputs(
        foregroundProcess: "vim",
        oscTitle: "SessionName.swift (violeet)",
        oscProcess: "vim",
        cwd: "/Users/grippado/www/personal/violeet"
    )
    #expect(SessionName.resolve(input).text == "SessionName.swift (violeet)")

    // vim exited without clearing its title. The stale title must not survive
    // it — this is the failure mode that makes OSC unusable as a primary
    // source.
    input.foregroundProcess = "zsh"
    let after = SessionName.resolve(input)
    #expect(after.text == "violeet")
    #expect(after.source == .directory)
}

@Test("an OSC title left by a different program does not name the current one")
func oscTitleFromAnotherProcessIsIgnored() {
    let input = NameInputs(
        foregroundProcess: "btop",
        oscTitle: "SessionName.swift (violeet)",
        oscProcess: "vim",
        cwd: "/Users/grippado/www/personal/violeet"
    )
    #expect(SessionName.resolve(input).text == "btop")
}

@Test("an OSC title set by the shell prompt never names the tab")
func oscTitleFromTheShellIsIgnored() {
    // zsh themes set the title constantly, and this is exactly what made OSC
    // unreliable: the title is the theme's idea of a prompt, not a name.
    let input = NameInputs(
        foregroundProcess: "zsh",
        oscTitle: "grippado@worzix: ~/www/personal/violeet",
        oscProcess: "zsh",
        cwd: "/Users/grippado/www/personal/violeet"
    )
    let name = SessionName.resolve(input)
    #expect(name.text == "violeet")
    #expect(name.source == .directory)
}

// MARK: - Whitespace

/// A field the user cleared and a field nobody ever filled must behave the
/// same. Otherwise a name of three spaces locks a tab into looking unnamed
/// with no way to see why.
@Test("a name that is only whitespace is no name at all")
func whitespaceIsNotAName() {
    let name = SessionName.resolve(
        NameInputs(manualName: "   ", agentTitle: "\n", cwd: "/etc")
    )
    #expect(name.text == "etc")
    #expect(name.source == .directory)
}


// MARK: - The file a tab was opened to edit

/// The bug this level exists for. Three tabs opened from the Files panel
/// were all called `nvim`, which is a tab strip that has stopped naming
/// anything.
@Test("an editor tab is named after its file, not after the editor")
func editingFileBeatsTheProcess() {
    let name = SessionName.resolve(
        NameInputs(foregroundProcess: "nvim", editingFile: "AppState.swift")
    )
    #expect(name.text == "AppState.swift")
}

/// Level 1 still wins. Nothing overrides the human, and a file is not an
/// exception to that.
@Test("a typed name still beats the file")
func manualBeatsTheFile() {
    let name = SessionName.resolve(
        NameInputs(manualName: "review", foregroundProcess: "nvim", editingFile: "AppState.swift")
    )
    #expect(name.text == "review")
    #expect(name.isLocked)
}

/// The file arrives before the first poll does, so a tab is named correctly
/// from the moment it appears rather than a beat later.
@Test("the file names the tab before any process is known")
func fileWorksWithoutAProcess() {
    let name = SessionName.resolve(NameInputs(cwd: "/Users/me/repo", editingFile: "README.md"))
    #expect(name.text == "README.md")
}

/// A tab that is not editing anything is unaffected — this level simply
/// does not apply, and the ladder below it is unchanged.
@Test("a tab with no file falls through to the process")
func noFileFallsThrough() {
    let name = SessionName.resolve(NameInputs(foregroundProcess: "btop", editingFile: nil))
    #expect(name.text == "btop")
}
