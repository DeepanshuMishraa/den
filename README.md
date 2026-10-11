# Den

A terminal, rebuilt from the demos of Superlogical's Rex: a native
macOS client on top of a persistent multiplexing server. The VT engine on both
sides is [libghostty-vt](https://github.com/ghostty-org/ghostty).

## Architecture

```
Den.app (AppKit + SwiftUI + Metal)            dend (Swift)
┌───────────────────────────────┐   unix   ┌──────────────────────────────┐
│ replica VTTerminal per pane    │◀────────│ PTY + authoritative          │
│   seeded from snapshot,        │ socket  │ VTTerminal per pane          │
│   advanced by raw VT bytes     │ binary  │ sessions → tabs → split tree │
│ Metal glyph-atlas renderer     │ frames  │ answers DSR/DA queries       │
│ key/mouse encoding from replica│────────▶│ outlives the app             │
└───────────────────────────────┘          └──────────────────────────────┘
```

- **Replicated state machines.** dend feeds PTY output into its own
  libghostty-vt terminal and forwards the same bytes to every attached client.
  On attach a client gets a libghostty snapshot (screen, scrollback, modes,
  unfinished escape) and then the stream, so its replica matches byte for byte.
  Resizes go through dend and come back in-stream, so every replica reflows the
  same way. Only dend answers terminal queries.
- **Local-first UI.** Scrollback, mode-aware key encoding (kitty protocol,
  DECCKM), mouse reporting and bracketed paste all run against the replica,
  with no round trip.
- **Persistent sessions.** The app starts dend in its own session (`setsid`), so
  quitting Den keeps every shell running. The next launch reattaches to the
  last session.

| Module | Role |
| --- | --- |
| `DenProtocol` | Framing, binary messages, split-tree model, socket helpers |
| `DenVT` | Swift wrapper over libghostty-vt: terminal, snapshot, render state, input encoders |
| `DenServer` / `dend` | Sessions, PTYs (`CDenPTY`), process metadata, broadcast |
| `DenApp` | Window chrome, deck tabs, session switcher, Metal terminal view |

## Build

```sh
git submodule update --init
scripts/build-libghostty-vt.sh   # fetches Zig 0.16 into .tools/, builds the xcframework
swift test
swift build && .build/debug/Den  # dev run (dend is started from next to the binary)
scripts/bundle.sh                # dist/Den.app
```

dend logs to `~/Library/Application Support/Den/dend.log` and listens on
`dend.sock` in the same folder. `pkill dend` ends all sessions.

## Shortcuts

| | |
| --- | --- |
| ⌘T / ⇧⌘W | New tab / close tab |
| ⌘D / ⇧⌘D | Split right / down |
| ⌘W | Close pane |
| ⇧⌘↩ | Zoom pane |
| ⌘[ ⌘] / ⇧⌘[ ⇧⌘] | Previous/next pane / tab |
| ⌘1…⌘9 | Select tab |
| ⌘K / ⇧⌘N | Session menu / new session |
| ⇧⌘P | Command palette |
| ⇧⌘G | Go to directory |
| 3-finger swipe ↓ / ↑ (or ⌃⌘↓ / ⌃⌘↑) | Tab peek → exposé, and back |
| ⌃⌘E | Exposé (all sessions) |
| ⌃⌘S | Vertical / horizontal tabs |
| ⌘= / ⌘- / ⌘0 | Bigger / smaller / actual font size |

## Client

- **Deck tabs**: fixed-width tabs, one capsule that springs to the active
  tab, dividers only between inactive tabs, drag to reorder, × on hover.
  Favicons are glossy program tiles with the tab's other panes fanned
  behind; a blue dot marks unseen activity.
- **Tab peek / exposé**: live miniature replicas under each tab, then a
  full-window grid of every session's tabs.
- **Session menu** (⌘K) and **command palette** (⇧⌘P) with fuzzy matching,
  chip submenus (Theme with live preview, Change/Rename Session, Rename Tab,
  Go to Directory, Add Host).
- **Vertical tabs** sidebar grouped by host and session.
- **Themes**: 41 built-ins (27 dark, 14 light) that tint the chrome too,
  System/Light/Dark appearance, import of Ghostty theme files and Omarchy
  theme folders, migration from your Ghostty config.
- **Automatic Contrast Correction**: low-contrast colors are corrected in
  OKLab toward the theme's foreground until they meet WCAG AA, memoized.
- **Fonts**: ships JetBrains Mono Nerd Font (OFL, the same default Ghostty
  embeds) so prompt icons work with no setup. Any font chosen in the palette
  (Change Font) falls back to a Nerd Font for icons before the system fallback.
- **Shell**: new panes use your account's login shell, or the one picked
  with Change Default Shell (stored as `shell = …` in
  `~/Library/Application Support/Den/config`).
- **Copy on select**: finishing a selection copies it and shows a toast.
- Selection with Ghostty's gesture rules (rounded highlight), ⌘C/⌘V, native
  overlay scrollbar, keycap tooltips.

## Development

- `DEN_SOCKET=/tmp/den-dev.sock .build/debug/Den` runs against a separate
  dend, leaving your real sessions alone.
- Debug builds accept `DEN_DEBUG_UI=peek|expose|vertical|palette|themes|sessions|split|tabs:N|session:NAME|theme:NAME`
  (comma separated) to open straight into a UI state.
- The protocol is versioned; after upgrading, restart dend once
  (`pkill dend`, which ends running sessions).

## Not yet

Remote hosts over Tailscale and the `den` CLI (the Add Host UI is present but
reports that this dend can't listen on the network), IME composition, new
windows.
