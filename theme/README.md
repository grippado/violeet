# Violeeter

A violet terminal palette, in two variants. It is the palette [Violeet](../)
ships with, published on its own because a palette is useful to people who will
never run the terminal it came from.

MIT. Take it, port it, change it.

| | |
|---|---|
| **Violeeter Dark** | `#24203F` ground. The default. |
| **Violeeter Light** | `#FAF8FE` ground. The same hue family, inverted properly rather than lightened. |

## Install

Every file in `dist/` is generated from `violeeter.json`. Pick your terminal:

| Terminal | File | Where |
|---|---|---|
| iTerm2 | `violeeter-{dark,light}.itermcolors` | double-click, then Settings → Profiles → Colors → Color Presets |
| Alacritty | `violeeter-{dark,light}.toml` | `import` it, or paste into `alacritty.toml` |
| Kitty | `violeeter-{dark,light}.conf` | `include violeeter-dark.conf` in `kitty.conf` |
| Ghostty | `violeeter-{dark,light}.ghostty` | paste into your config |
| Windows Terminal | `violeeter-{dark,light}.json` | add to `schemes` in `settings.json` |
| Web / anything | `violeeter.css` | custom properties, dark by `prefers-color-scheme` |

Violeet itself has them built in — Settings → Appearance.

## What the two variants are for

The dark one is the reason the terminal is called what it is. Its ground is
`#24203F`, and the two points worth knowing are both consequences of a violet
background rather than a black one:

- **Blue had to move.** Default terminal blue sits a few degrees from this
  ground and the two stop separating. It is lifted and pulled toward cyan.
- **Neutral grey reads yellow** against a cold ground, so the foreground carries
  a trace of the same hue instead of being a true grey.

The light one is not the dark one with the lightness flipped. Flipping a palette
produces colours that are technically inverted and practically unreadable —
pastels on white. Each colour was re-picked at a luminance that clears the
contrast floor on a pale ground, keeping the hue.

## Contrast

Every colour that can carry text clears **WCAG AA (4.5:1)** against its own
background. This is checked, not asserted:

```
python3 build.py --check
```

| Variant | Worst text contrast |
|---|---|
| Violeeter Dark | 4.53 (`brightBlack`) |
| Violeeter Light | 5.06 (`green`) |

Two slots are exempt, and only in the light variant: `white` and `brightWhite`.
They mean "the palest thing here", and on a pale ground that is a surface you
fill with, not something you write with. Holding them to a text ratio would mean
darkening white until it stopped being white.

One honest note about the dark variant: `brightBlack` was `#554F7E` in the
terminal this palette grew up in, and that measures **2.07** — well under AA.
That slot is where nearly every syntax highlighter puts *comments*, so shipping
it meant shipping unreadable comments. It is `#8B84BC` here, the smallest step
that clears the floor while keeping the hue.

## Editing

`violeeter.json` is the only file anyone edits. Everything in `dist/` is
generated:

```
python3 build.py
```

A palette copied by hand into six terminal formats drifts, and a palette that is
*almost* the same in two terminals is worse than two different palettes — the
difference reads as a rendering bug rather than as a choice.
