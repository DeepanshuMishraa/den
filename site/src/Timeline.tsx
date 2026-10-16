import { reveal } from './reveal'

// Timeline geometry in viewBox units. The app's lifeline breaks between
// QUIT and OPEN; the shell lifelines below it never do.
const START = 88
const END = 680
const QUIT = 330
const OPEN = 460

const shells = [
  { name: 'zsh', y: 64 },
  { name: 'htop', y: 92 },
  { name: 'make', y: 120 },
] as const

const APP_Y = 24

/** Lifelines of the app and its shells, with a playhead sweeping across. */
export function Timeline() {
  return (
    <figure className="timeline reveal" ref={reveal}>
      <svg viewBox="0 0 680 150" role="img" aria-labelledby="timeline-title">
        <title id="timeline-title">
          A timeline: Den.app quits and reopens later, while the zsh, htop and make shells keep running the whole time.
        </title>

        <text className="t-name t-name-app" x="0" y={APP_Y + 4}>den.app</text>
        <line className="t-life t-app" x1={START} y1={APP_Y} x2={QUIT} y2={APP_Y} pathLength={1} />
        <line className="t-gap" x1={QUIT + 8} y1={APP_Y} x2={OPEN - 8} y2={APP_Y} />
        <line className="t-life t-app t-app-2" x1={OPEN} y1={APP_Y} x2={END} y2={APP_Y} pathLength={1} />
        <circle className="t-node" cx={QUIT} cy={APP_Y} r="3" />
        <circle className="t-node" cx={OPEN} cy={APP_Y} r="3" />
        <text className="t-mark" x={QUIT} y={APP_Y - 10} textAnchor="middle">quit</text>
        <text className="t-mark" x={OPEN} y={APP_Y - 10} textAnchor="middle">reopen</text>

        {shells.map((shell, i) => (
          <g key={shell.name}>
            <text className="t-name" x="0" y={shell.y + 4}>{shell.name}</text>
            <line
              className="t-life t-shell"
              x1={START}
              y1={shell.y}
              x2={END}
              y2={shell.y}
              pathLength={1}
              style={{ animationDelay: `${0.15 + i * 0.12}s` }}
            />
          </g>
        ))}

        <g className="t-head">
          <line className="t-head-line" x1={START} y1={APP_Y - 4} x2={START} y2={134} />
          <circle className="t-dot t-dot-app" cx={START} cy={APP_Y} r="3.5" />
          {shells.map((shell) => (
            <circle key={shell.name} className="t-dot" cx={START} cy={shell.y} r="3.5" />
          ))}
        </g>
      </svg>
    </figure>
  )
}
