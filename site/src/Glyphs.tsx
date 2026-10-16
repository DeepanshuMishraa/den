import type { StepGlyph } from './content'

const Window = ({ className }: { className?: string }) => (
  <g className={className}>
    <rect x="3" y="5" width="18" height="14" rx="2" pathLength={1} />
    <line x1="3" y1="9" x2="21" y2="9" pathLength={1} />
  </g>
)

/** Small looping illustration for each "how it works" step. */
export function Glyph({ kind }: { kind: StepGlyph }) {
  return (
    <svg className={`glyph glyph-${kind}`} viewBox="0 0 24 24" width="24" height="24" aria-hidden="true">
      {kind === 'quit' && (
        <>
          <Window className="g-win" />
          <rect className="g-dot" x="6" y="12" width="2.5" height="4" rx="0.4" />
        </>
      )}
      {kind === 'reopen' && <Window className="g-draw" />}
      {kind === 'remote' && (
        <>
          <circle className="g-core" cx="12" cy="16" r="2" />
          <path className="g-arc g-arc-1" d="M8 12.5 A5 5 0 0 1 16 12.5" />
          <path className="g-arc g-arc-2" d="M5 9.5 A9 9 0 0 1 19 9.5" />
        </>
      )}
    </svg>
  )
}
