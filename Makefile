# violeet — local development loop.
#
# This file adds no build logic. The two shell scripts under `app/scripts` are
# still the only things that know how to produce and place a bundle, and CI runs
# those, not this. What lives here is the *sequence* — quit, package, install,
# restart the daemon, reopen — which is the part that was being retyped from
# memory and getting done in the wrong order.
#
# The order matters more than it looks. `install.sh` replaces a bundle the
# running app is executing from, and the daemon travels inside that bundle, so
# an install that skips the quit leaves a live process pointing at a path that
# no longer exists. `make reinstall` is that sequence written down once.
#
# Run `make` for the list.

SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_BUNDLE  := /Applications/violeet.app
APP_CLI     := $(APP_BUNDLE)/Contents/Resources/violeet
DAEMON_LABEL := digital.opengateway.violeet.daemon
DAEMON_DIR  := $(HOME)/.violeet
DAEMON_PLIST := $(HOME)/Library/LaunchAgents/$(DAEMON_LABEL).plist

.PHONY: help
help: ## Show this list
	@echo "violeet — local targets"
	@echo
	@grep -hE '^[a-z][a-z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo

# ---------------------------------------------------------------------------
# Compile and check
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Debug build of the Rust workspace
	cargo build --workspace

.PHONY: test
test: test-rust test-swift test-install ## Run every suite

.PHONY: test-rust
test-rust: ## cargo test --workspace
	cargo test --workspace

.PHONY: test-swift
test-swift: ## swift test (the app suite lives under app/)
	cd app && swift test

# Runs a copy of install.sh against a temporary directory, never the real
# /Applications and never the real Trash, so it is safe from any checkout.
.PHONY: test-install
test-install: ## Check that install.sh quarantines only violeet bundles
	app/scripts/test-install-quarantine.sh

.PHONY: lint
lint: ## clippy plus a formatting check, neither of which writes
	cargo clippy --all-targets
	cargo fmt --check

.PHONY: fmt
fmt: ## Format the Rust sources in place
	cargo fmt

# ---------------------------------------------------------------------------
# Package and install
# ---------------------------------------------------------------------------
#
# `package.sh` stamps the bundle with the commit it was cut from, and appends
# `-dirty` when the tree has uncommitted changes. That suffix is not a warning
# to be silenced: a bundle built over a dirty tree is not the commit it names,
# and the About panel is where that gets discovered instead of in a bug report
# that will not reproduce.

.PHONY: package
package: ## Build the universal .app and zip it into app/dist (no .dmg)
	app/scripts/package.sh --skip-dmg

.PHONY: dmg
dmg: ## Same as package, plus the .dmg
	app/scripts/package.sh

.PHONY: install
install: ## Install the newest zip from app/dist into /Applications
	app/scripts/install.sh

.PHONY: reinstall
reinstall: quit package install daemon-restart run ## Full loop: quit, build, install, restart the daemon, reopen
	@echo "==> installed: $$(defaults read $(APP_BUNDLE)/Contents/Info CFBundleShortVersionString) \
	(build $$(defaults read $(APP_BUNDLE)/Contents/Info CFBundleVersion), \
	commit $$(defaults read $(APP_BUNDLE)/Contents/Info VioleetGitCommit))"

.PHONY: version
version: ## What is installed right now
	@test -d $(APP_BUNDLE) || { echo "not installed: $(APP_BUNDLE)"; exit 1; }
	@echo "version: $$(defaults read $(APP_BUNDLE)/Contents/Info CFBundleShortVersionString)"
	@echo "build:   $$(defaults read $(APP_BUNDLE)/Contents/Info CFBundleVersion)"
	@echo "commit:  $$(defaults read $(APP_BUNDLE)/Contents/Info VioleetGitCommit)"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
#
# `quit` sends a Quit Apple Event to the app by name, which is addressed and
# waits for the app to tear its windows down. It is deliberately not a `kill`:
# the app writes its preferences and its window frame on the way out, and a
# killed app loses both.

.PHONY: run
run: ## Open the installed app
	open -a $(APP_BUNDLE)

.PHONY: quit
quit: ## Ask the running app to quit, if there is one
	@osascript -e 'tell application "violeet" to quit' 2>/dev/null || true
	@sleep 2

# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------
#
# The daemon runs under launchd from inside the installed bundle, so replacing
# the bundle does not replace the running process. Every install needs the
# restart below or the board keeps being served by the binary you just
# overwrote — which looks exactly like a fix that did not work.
#
# `stop` and `start` are not symmetrical, and finding that out the hard way is
# why they are written down. `bootout` does not pause the job, it *removes it
# from the domain*: afterwards `launchctl print` cannot find the label at all
# and `kickstart` fails with "Could not find service" rather than starting
# anything. The way back is `bootstrap` with the plist, which is what
# `daemon-start` does. Measured, not assumed — the cycle was run.
#
# One visible side effect of that round trip: the app registers the job through
# ServiceManagement (`type = Submitted`), while `bootstrap` re-registers it as a
# plain `LaunchAgent`. Same binary, same plist, same behaviour; only the
# provenance line in `launchctl print` changes.

.PHONY: daemon-restart
daemon-restart: ## Restart the daemon (required after every install)
	@if launchctl kickstart -k "gui/$$(id -u)/$(DAEMON_LABEL)" 2>/dev/null; then \
		:; \
	else \
		echo "==> not in the domain (stopped earlier?); bootstrapping instead"; \
		launchctl bootstrap "gui/$$(id -u)" "$(DAEMON_PLIST)"; \
	fi
	@sleep 1
	@pgrep -fl violeet-daemon || echo "!! daemon is not running"

.PHONY: daemon-stop
daemon-stop: ## Stop the daemon, to see the board degrade honestly (come back with daemon-start)
	launchctl bootout "gui/$$(id -u)/$(DAEMON_LABEL)" 2>/dev/null || true
	@sleep 1
	@pgrep -fl violeet-daemon || echo "daemon stopped — 'make daemon-start' brings it back"

.PHONY: daemon-start
daemon-start: ## Bring the daemon back after daemon-stop
	@test -f "$(DAEMON_PLIST)" || { \
		echo "no plist at $(DAEMON_PLIST) — open the app once, it writes it on launch"; exit 1; }
	launchctl bootstrap "gui/$$(id -u)" "$(DAEMON_PLIST)"
	@sleep 1
	@pgrep -fl violeet-daemon || echo "!! daemon did not come up"

.PHONY: daemon-status
daemon-status: ## Is it running, and what did it publish about itself
	@pgrep -fl violeet-daemon || echo "daemon not running"
	@test -f $(DAEMON_DIR)/daemon.json && cat $(DAEMON_DIR)/daemon.json || true

.PHONY: daemon-log
daemon-log: ## Follow the daemon log
	tail -f $(DAEMON_DIR)/daemon.log

.PHONY: snapshot
snapshot: ## Ask the socket for the current board, as JSON lines
	@python3 -c 'import socket,os,sys;\
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);\
s.connect(os.path.expanduser("~/.violeet/daemon.sock"));\
s.sendall(b"{\"type\":\"request_snapshot\",\"v\":1,\"ts\":\"1970-01-01T00:00:00Z\"}\n");\
s.settimeout(3);\
[sys.stdout.write(c.decode("utf-8","replace")) for c in iter(lambda: s.recv(65536), b"")]' 2>/dev/null || true

.PHONY: doctor
doctor: ## Run the installed CLI's own diagnosis
	$(APP_CLI) doctor

# These two are the only targets in this file that write outside the repository.
# `install-hooks` edits `~/.claude/settings.json` — your global Claude Code
# configuration, shared by every project on the machine, not something scoped to
# this checkout. Reinstalling the app does not re-run them and uninstalling it
# does not undo them: the hooks outlive the bundle and keep pointing at a daemon
# path that may no longer exist. `make unhooks` is the only thing that removes
# them.

.PHONY: hooks
hooks: ## Point Claude Code's hooks at this daemon (WRITES ~/.claude/settings.json)
	$(APP_CLI) install-hooks

.PHONY: unhooks
unhooks: ## Remove those hooks again (WRITES ~/.claude/settings.json)
	$(APP_CLI) uninstall-hooks

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

.PHONY: xcode
xcode: ## Generate and open the Xcode project (for debugging, not for shipping)
	cd app && xcodegen generate && open Violeet.xcodeproj

# `install` takes the *newest zip in app/dist* when given no argument, so this
# target and that one are ordered: `make clean install` fails with "no build to
# install", and the message does not point back at the clean that caused it.
# Reach for `make reinstall`, which packages before it installs.
#
# Worth knowing before the first run: `app/dist` accumulates. It still holds the
# `aiterm-*` bundles from before the rename, dozens of them, which is disk and
# nothing else — `install` only ever reads the newest.

.PHONY: clean
clean: ## Remove build output from both toolchains (also wipes app/dist, which install reads from)
	cargo clean
	rm -rf app/.build app/dist
