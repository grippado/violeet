# Sidebar

Pure SwiftUI. One card per agent session: state, model, context fill, last
action, and any pending HITL request.

A HITL card is answerable in place — that is the point of the product — but it
is racing the agent's own TUI dialog, which stays live in the tab. See
`docs/adr/ADR-004`.

## What is here today

One row per **tab**, showing its working directory, and a status line saying
whether the daemon is reachable. Not one card, not a placeholder card.

That is deliberate. The cards above are the product, and they are worth
designing against real session data rather than against a guess at its shape —
a stubbed card is a layout decision made before the inputs exist, and it gets
defended later because it is already there. `AppState` does decode and store
every `session_registered`, `session_updated` and `hitl_pending` the daemon
sends, so the data is arriving and observable; it simply is not drawn yet.

What this version is for is the plumbing under the cards: that tabs and PTYs
behave, that the socket connects and reconnects, and that a missing daemon costs
the sidebar its data and costs the terminal nothing. The status line at the
bottom is the visible half of that last claim — no alert, no modal, no red,
because there is nothing for the user to do about it.

## Rows observe their own tab

`TabRow` takes an `@ObservedObject var tab: TabModel`, so a `cd` in one tab
redraws one row instead of the list. It matters more than it looks: the cwd is
polled per tab, so a list-level redraw would repaint every row on every poll of
any tab.
