# Violeeter, vendored

Violeet ships with [Violeeter](https://github.com/grippado/violeeter). The theme
lives in its own repository, because it is useful to people who will never run
this terminal — that is the whole reason it was split out.

These two files are **copies**, and this directory is the only place they may be
edited from: upstream.

| File | Used by |
|---|---|
| `violeeter.json` | the app's palette test, which compares `TerminalTheme.builtins` against it |
| `violeeter.css` | copied into `docs/` for the project page |

## Why vendored rather than a submodule

A submodule would make a clone of this repository useless until someone ran a
second command, and would put a network fetch between a contributor and
`swift test`. The palette is one small file that changes rarely; a copy costs a
sync step at that rare moment and nothing the rest of the time.

## Updating

```sh
scripts/sync-theme.sh            # from a checkout of grippado/violeeter beside this one
```

The script refuses to run if the app's built-in palette would stop matching, so
a sync that drifts the theme is caught here rather than by a test somewhere
else.
