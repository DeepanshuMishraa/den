export const links = {
  repo: 'https://github.com/DeepanshuMishraa/den',
  releases: 'https://github.com/DeepanshuMishraa/den/releases',
  issues: 'https://github.com/DeepanshuMishraa/den/issues',
  download: 'https://github.com/DeepanshuMishraa/den/releases/latest/download/Den-macos-arm64.dmg',
} as const

export const steps = [
  { glyph: 'quit', name: 'quit', text: 'Den.app is only a window. Your shells live in dend, a small server that outlives it.' },
  { glyph: 'reopen', name: 'reopen', text: 'The next launch reattaches to your last session: screen, scrollback and modes, byte for byte.' },
  { glyph: 'remote', name: 'remote', text: 'The same dend runs on Linux over ssh. Drop the connection and the sessions keep going.' },
] as const

export type StepGlyph = (typeof steps)[number]['glyph']

export const features = [
  { name: 'sessions', text: 'Sessions, tabs and split panes. ⌘K to switch, exposé to see them all.' },
  { name: 'render', text: 'Metal glyph-atlas renderer. Scrollback and key encoding run locally.' },
  { name: 'remote', text: 'Your own ssh, so ~/.ssh/config, ProxyJump and Tailscale SSH apply.' },
  { name: 'status', text: 'Tabs show when a program is working, waiting on you, or done.' },
  { name: 'themes', text: '41 built-ins that tint the chrome too. Ghostty themes import as is.' },
  { name: 'contrast', text: 'Den fixes low-contrast colors in OKLab until they pass WCAG AA.' },
  { name: 'fonts', text: 'Ships JetBrains Mono Nerd Font, so prompt icons just work.' },
  { name: 'config', text: 'One TOML file. Rebind anything, reloaded when Den comes to the front.' },
] as const

export const commands = [
  { cmd: 'den new video -- htop', text: 'new session' },
  { cmd: 'den split --label build -- make', text: 'split a pane' },
  { cmd: 'den wait -p build', text: 'exit with its status' },
  { cmd: "den send -p nvim --enter ':w'", text: 'type into a pane' },
  { cmd: 'den capture -p build --lines 20', text: 'read its output' },
  { cmd: 'den events -s video', text: 'live event stream' },
] as const

export const shortcuts = [
  { keys: ['⌘', 'D'], text: 'split right' },
  { keys: ['⇧', '⌘', 'D'], text: 'split down' },
  { keys: ['⌘', 'K'], text: 'sessions' },
  { keys: ['⇧', '⌘', 'P'], text: 'command palette' },
  { keys: ['⇧', '⌘', '↩'], text: 'zoom pane' },
  { keys: ['⌃', '⌘', 'E'], text: 'exposé' },
] as const
