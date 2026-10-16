import { useRef, useState } from 'react'

export function CopyCommand({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  const resetRef = useRef<ReturnType<typeof setTimeout>>(undefined)

  async function copy() {
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      // Clipboard access denied. The command stays visible and selectable.
      return
    }
    setCopied(true)
    clearTimeout(resetRef.current)
    resetRef.current = setTimeout(() => setCopied(false), 1600)
  }

  return (
    <div className="command">
      <code>
        <span className="dollar">$</span> {text}
      </code>
      <button type="button" className="ghost" onClick={copy} aria-label={`Copy ${text}`}>
        <span className="swap" data-on={copied}>
          <span>copy</span>
          <span>copied</span>
        </span>
      </button>
    </div>
  )
}
