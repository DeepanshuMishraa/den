import { AppleLogo } from './brand'
import { CopyCommand } from './CopyCommand'
import { commands, features, links, shortcuts, steps } from './content'
import { Glyph } from './Glyphs'
import { reveal } from './reveal'
import { Timeline } from './Timeline'

export default function App() {
  return (
    <main>
      <header className="reveal" ref={reveal}>
        <a className="brand" href="#top" aria-label="Den home">
          <img src="/icon.png" alt="" width={28} height={28} />
          den
        </a>
        <nav>
          <a href="#how">how</a>
          <a href="#features">features</a>
          <a href="#cli">cli</a>
          <a href={links.repo}>github</a>
        </nav>
      </header>

      <div className="hero" id="top">
        <h1 className="reveal" ref={reveal}>
          Quit the terminal.
          <br />
          <strong>The shells stay.</strong>
        </h1>
        <p className="sub reveal" ref={reveal}>
          Den is a native macOS terminal on a persistent server. Close the app and every shell keeps running. Open it
          again, or reach the same sessions on another machine over ssh.
        </p>
        <Timeline />
        <div className="actions reveal" ref={reveal}>
          <a className="button" href={links.download}>
            <AppleLogo />
            download for mac
          </a>
          <span>
            apple silicon · macOS 15+ · <a href={links.repo}>source</a>
          </span>
        </div>
      </div>

      <section className="reveal" ref={reveal} id="how" aria-labelledby="how-h">
        <h2 id="how-h">How it works</h2>
        {steps.map((step) => (
          <div className="row steps-row" key={step.name}>
            <Glyph kind={step.glyph} />
            <span className="strong">{step.name}</span>
            <span className="mute">{step.text}</span>
          </div>
        ))}
      </section>

      <section className="reveal" ref={reveal} id="features" aria-labelledby="features-h">
        <h2 id="features-h">Features</h2>
        {features.map((feature) => (
          <div className="row pair-row" key={feature.name}>
            <span className="strong">{feature.name}</span>
            <span className="mute">{feature.text}</span>
          </div>
        ))}
      </section>

      <section className="reveal" ref={reveal} id="cli" aria-labelledby="cli-h">
        <h2 id="cli-h">CLI</h2>
        {commands.map((command) => (
          <div className="row cmd-row" key={command.cmd}>
            <code>{command.cmd}</code>
            <span className="mute small">{command.text}</span>
          </div>
        ))}
        <p className="note">Every change shows up in the window at once. Inside a pane, -s and -p default to that pane.</p>
      </section>

      <section className="reveal" ref={reveal} aria-labelledby="agents-h">
        <h2 id="agents-h">For agents</h2>
        <p className="mute">
          Coding agents drive Den through the same CLI. They open a dev server in a split beside them, read its output
          and type into it. One command installs the skill for Claude Code and other skill-aware agents.
        </p>
        <CopyCommand text="den agent install" />
      </section>

      <section className="reveal" ref={reveal} aria-labelledby="keys-h">
        <h2 id="keys-h">Shortcuts</h2>
        <div className="keys">
          {shortcuts.map((shortcut) => (
            <div className="key-row" key={shortcut.text}>
              <span className="caps">
                {shortcut.keys.map((key) => (
                  <kbd key={key}>{key}</kbd>
                ))}
              </span>
              <span className="mute small">{shortcut.text}</span>
            </div>
          ))}
        </div>
      </section>

      <footer className="reveal" ref={reveal}>
        <span>2026 den</span>
        <nav>
          <a href={links.releases}>releases</a>
          <a href={links.issues}>issues</a>
          <a href={links.repo}>github</a>
        </nav>
      </footer>
    </main>
  )
}
