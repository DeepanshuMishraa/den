import Foundation
import DenProtocol

/// `den config help`: a manual for everything Den can be configured with,
/// in man-page shape. Command lists come from `DenCommand`, so they can't
/// drift from the app.
enum ConfigManual {
    struct Topic: Sendable {
        let name: String
        let heading: String
        let body: @Sendable () -> String
    }

    static var topicNames: String { topics.map(\.name).joined(separator: ", ") }

    static func text(topic: String?) -> String? {
        guard let topic else {
            return header + topics.map(render).joined(separator: "\n") + footer
        }
        return topics.first { $0.name == topic.lowercased() }.map(render)
    }

    private static func render(_ topic: Topic) -> String {
        CLIOutput.bold(topic.heading) + "\n" + indent(topic.body()) + "\n"
    }

    private static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "       " + $0 }.joined(separator: "\n")
    }

    private static let bundleID = "den.dipxsy.app"

    private static var header: String {
        """
        \(CLIOutput.bold("DEN-CONFIG(5)"))                      Den Manual                      \(CLIOutput.bold("DEN-CONFIG(5)"))

        \(CLIOutput.bold("NAME"))
               den-config — every way to set up Den: config.toml, keys, app
               settings, the shell, themes, remote hosts and environment

        \(CLIOutput.bold("SYNOPSIS"))
               den config help [TOPIC]      this manual, or one section of it
               den config path              where each file lives
               den config check             validate config.toml
               den keybinds                 every shortcut, set or not

               Topics: \(topicNames)


        """
    }

    private static var footer: String {
        """

        \(CLIOutput.bold("SEE ALSO"))
               den help, den keybinds, den config check

        """
    }

    static let topics: [Topic] = [
        Topic(name: "files", heading: "FILES") {
            """
            \(UserConfig.url.path)
                config.toml, the file you edit. Keys, Option-as-Alt and extra
                bindings live here. Missing keys keep their defaults. Honors
                $XDG_CONFIG_HOME instead of ~/.config. "Open Config File…" (⌘,)
                creates it with every command listed and commented out.

            \(DenConfig.url.path)
                key = value settings shared by the app and dend. Den writes it
                (today only `shell`); you may edit it too. See SHELL.

            \(DenPaths.themes.path)
                Themes you imported, one Ghostty-format .conf file each.

            \(DenPaths.socket.path)
                dend's socket. Den, den and remote Dens all talk to dend here.

            \(DenPaths.log.path)
                dend's log. Look here when sessions fail to start.

            App settings (font, theme, layout) are macOS user defaults in the
            \(bundleID) domain; see SETTINGS.
            """
        },
        Topic(name: "options", heading: "CONFIG.TOML OPTIONS") {
            """
            macos_option_as_alt = true | false | "left" | "right"
                Whether Option sends Alt (ESC-prefixed keys, what shells and
                editors expect for M-x) or types symbols like å. "left"/"right"
                use only that Option key as Alt. Default: true.

            Changes apply when Den comes back to the front, or at once with
            "Reload Config" (⇧⌘,). A mistake is reported in Den and the last
            working config stays active; `den config check` shows the error.

            Typographic quotes (“ ” ‘ ’, as TextEdit inserts them) are read as
            straight quotes, so pasting from notes works.
            """
        },
        Topic(name: "keys", heading: "KEYS") {
            """
            The [keys] table changes the shortcut of any Den command:

                [keys]
                leader = "opt+space"
                split_right = "leader+\\\\"
                new_tab = "cmd+t"
                close_tab = ""            # "" removes the shortcut

            \(CLIOutput.bold("Key syntax"))
                Modifiers joined with + and then one key:
                  modifiers   cmd (command, super), ctrl (control),
                              opt (option, alt), shift
                  keys        one character: a, \\, [, =, ...
                              names: enter (return), tab, space, escape (esc),
                              backspace, delete, up, down, left, right, home,
                              end, page_up, page_down, f1 ... f12
                              digit (also 1..9): any number key; only for
                              go_to_tab and go_to_session, the number picks
                              the target
                "cmd++" binds plus. Case doesn't matter.

            \(CLIOutput.bold("Leader"))
                "leader+n" means: press the leader, let go, then n. The leader is
                opt+space unless [keys] leader says otherwise. Pressing the
                leader twice sends it to the program.

            \(CLIOutput.bold("Commands and their defaults"))
            \(commandTable)

            `den keybinds` shows what is bound right now, including commands
            with no shortcut ("not set") and which ones you changed.
            """
        },
        Topic(name: "binds", heading: "EXTRA BINDINGS ([[keys.bind]])") {
            """
            Each [[keys.bind]] entry maps a key to an action. They're checked
            before the shortcuts above, and later entries win.

                [[keys.bind]]
                key = "cmd+a"             # same syntax as KEYS, leader+ too
                action = 'text:\\x1ba'

            Actions:
                a command name      e.g. "split_right"; runs that command
                'text:BYTES'        sends BYTES to the program. Escapes:
                                    \\xNN (hex byte), \\e (ESC), \\n, \\r, \\t, \\\\
                'passthrough'       sends the key to the program, not Den
                'ignore'            does nothing

            Use single quotes for text actions so backslashes stay as written.

            Example, Neovim's ⌘S/⌘C as Alt keys:
                [[keys.bind]]
                key = "cmd+s"
                action = 'text:\\x1bs'

                [[keys.bind]]
                key = "cmd+c"
                action = 'text:\\x1bc'
            """
        },
        Topic(name: "shell", heading: "SHELL") {
            """
            New panes run, in order of preference:
                1. `shell = /path/to/shell` in \(DenConfig.url.lastPathComponent)
                   (set it from the command palette, or edit the file)
                2. your account's login shell (chsh)
                3. $SHELL, then /bin/zsh, /bin/bash, /bin/sh

            The shell starts as a login shell, so it reads your profile even
            though dend was started by the app. Commands given to den (den new
            NAME -- htop) run through that shell too, so they see your PATH.

                \(CLIOutput.dim("# ~/Library/Application Support/Den/config"))
                shell = /opt/homebrew/bin/fish

            Takes effect for panes created afterwards.
            """
        },
        Topic(name: "settings", heading: "SETTINGS (APP PREFERENCES)") {
            """
            Den saves these when you change them in the app (command palette,
            View menu). They can also be scripted with `defaults` while Den is
            quit:

                defaults write \(bundleID) fontSize -float 14

            fontFamily          string   default "\(FontRegistry.bundledFamily)"
            fontSize            float    8–32, default \(Int(FontMetrics.defaultSize))
            appearance          string   \(AppearanceMode.allCases.map(\.rawValue).joined(separator: " | "))
            lightTheme          string   theme used in light mode, default "\(ThemeCatalog.defaultLight)"
            darkTheme           string   theme used in dark mode, default "\(ThemeCatalog.defaultDark)"
            interfaceStyle      string   \(InterfaceStyle.allCases.map(\.rawValue).joined(separator: " | ")), default themed
            density             string   \(Density.allCases.map(\.rawValue).joined(separator: " | "))
            tabStyle            string   horizontal | vertical
            sidebarCollapsed    bool     vertical tabs folded away
            activityMode        bool     sidebar lists only tabs with agents/status
            showPaneHeaders     bool     default true
            acc                 bool     automatic contrast correction, default true

            Builds run with `swift run` keep their defaults under a different
            domain than the bundled Den.app.
            """
        },
        Topic(name: "themes", heading: "THEMES") {
            """
            Den ships light and dark themes and follows the system appearance
            unless `appearance` says otherwise. "Change Theme…" previews as you
            move through the list.

            Import: any Ghostty theme file, or an Omarchy theme folder that has a
            ghostty.conf. Den copies it to \(DenPaths.themes.path), so it
            survives restarts. Writing a .conf file there by hand works too:

                background = #1e1e2e
                foreground = #cdd6f4
                cursor-color = #f5e0dc
                palette = 0=#45475a
                ...
                palette = 15=#a6adc8
            """
        },
        Topic(name: "ghostty", heading: "MIGRATING FROM GHOSTTY") {
            """
            Den can read your Ghostty config and carry over macos-option-as-alt
            and keybinds that map to Den commands or text, writing them into
            config.toml. Run it from the command palette.
            """
        },
        Topic(name: "remote", heading: "REMOTE HOSTS") {
            """
            "Add Remote Host…" (leader+x) connects Den to another machine over
            your system ssh (so ~/.ssh/config, keys, Tailscale names and jump
            hosts all work). Den installs dend there under ~/.den/bin and runs
            `dend --stdio`, so remote sessions persist across dropped
            connections exactly like local ones. Saved passwords go to the
            Keychain.
            """
        },
        Topic(name: "environment", heading: "ENVIRONMENT") {
            """
            Read by Den and den:
                DEN_SOCKET        dend socket to use instead of the default
                XDG_CONFIG_HOME   base folder for den/config.toml
                PAGER             pager for this manual (default less -R)

            Set in every pane:
                DEN_PANE_ID       this pane's ID; den uses it as the default -p
                DEN_SESSION_ID    this pane's session; the default -s
                DEN_SOCKET        the dend that owns the pane
                TERM=xterm-256color, COLORTERM=truecolor, TERM_PROGRAM=Den
                PATH              gains Den.app's bin folder, so `den` works
            """
        },
        Topic(name: "cli", heading: "THE DEN COMMAND") {
            """
            `den` ships inside Den.app (Contents/Resources/bin/den). Den links it
            to ~/.local/bin/den when it starts, and every Den pane has it on
            PATH. If ~/.local/bin isn't on your PATH elsewhere, add it, or link
            it yourself:

                ln -sf /Applications/Den.app/Contents/Resources/bin/den /usr/local/bin/den

            `den help` lists its commands.
            """
        },
        Topic(name: "examples", heading: "EXAMPLES") {
            """
            A minimal config.toml:

                macos_option_as_alt = "left"

                [keys]
                leader = "ctrl+a"
                new_tab = "cmd+t"
                split_right = "cmd+d"
                split_down = "cmd+shift+d"
                last_tab = "cmd+9"

                [[keys.bind]]
                key = "cmd+k"
                action = 'text:\\x0c'      # clear the screen (ctrl+l)

            Then:
                den config check
                den keybinds --custom
            """
        },
    ]

    private static var commandTable: String {
        let width = DenCommand.allCases.map(\.rawValue.count).max() ?? 0
        return DenCommand.allCases.map { c in
            "    \(c.rawValue.padding(toLength: width, withPad: " ", startingAt: 0))  \((c.defaultShortcut ?? "not set").padding(toLength: 18, withPad: " ", startingAt: 0))  \(c.title)"
        }.joined(separator: "\n")
    }
}
