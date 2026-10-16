let observer: IntersectionObserver | undefined

// One observer for the page, so elements that enter the viewport together
// get consecutive --i values and fade in staggered.
function shared() {
  observer ??= new IntersectionObserver(
    (entries, obs) => {
      entries
        .filter((entry) => entry.isIntersecting)
        .forEach((entry, i) => {
          const el = entry.target
          if (el instanceof HTMLElement) el.style.setProperty('--i', String(i))
          el.classList.add('in')
          obs.unobserve(el)
        })
    },
    { rootMargin: '0px 0px -8% 0px' },
  )
  return observer
}

/** Ref callback: pass as `ref={reveal}` on an element with the `reveal` class. */
export function reveal(el: HTMLElement | null) {
  if (!el) return
  const obs = shared()
  obs.observe(el)
  return () => obs.unobserve(el)
}
