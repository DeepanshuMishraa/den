import { useEffect, useRef, useState } from 'react'
import { AppleLogo } from './brand'
import { links } from './content'
import { CopyCommand } from './CopyCommand'

const COUNTDOWN = 5
const UNQUARANTINE = 'sudo xattr -dr com.apple.quarantine /Applications/Den.app'

export function DownloadButton() {
  const dialogRef = useRef<HTMLDialogElement>(null)
  const [left, setLeft] = useState<number | null>(null)

  useEffect(() => {
    if (left === null) return
    if (left === 0) {
      window.location.href = links.download
      return
    }
    const id = setTimeout(() => setLeft(left - 1), 1000)
    return () => clearTimeout(id)
  }, [left])

  function open(event: React.MouseEvent) {
    // The plain link still works without JS; with JS we warn first.
    event.preventDefault()
    dialogRef.current?.showModal()
    setLeft(COUNTDOWN)
  }

  function close() {
    dialogRef.current?.close()
  }

  return (
    <>
      <a className="button" href={links.download} onClick={open}>
        <AppleLogo />
        download for mac
      </a>
      <dialog ref={dialogRef} className="notice" onClose={() => setLeft(null)} aria-labelledby="notice-h">
        <h2 id="notice-h">Den isn't signed yet</h2>
        <p className="mute">
          macOS will say the app is damaged or from an unidentified developer. After moving Den to Applications, run
          this once to clear the quarantine flag:
        </p>
        <CopyCommand text={UNQUARANTINE} />
        <div className="notice-actions">
          <button type="button" className="ghost" onClick={close}>
            cancel
          </button>
          <span className="mute small" aria-live="polite">
            {left === 0 ? 'downloading…' : `download starts in ${left ?? COUNTDOWN}s`}
          </span>
        </div>
      </dialog>
    </>
  )
}
