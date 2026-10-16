import DenProtocol
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// The window's coordinate space, origin top-left: pane frames for ⌘-drag
    /// hit-testing and the drag card are both in it.
    static let space = "den.window"
    /// Gap between the toast pill and the window edges it sits against.
    static let toastInset: CGFloat = 16

    var body: some View {
        let theme = model.theme
        let surfaces = model.surfaces
        // 0 → 1 as the overview goes from peek to exposé.
        let expose = min(max(model.overviewLevel - 1, 0), 1)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [surfaces.windowTop, surfaces.windowBottom], startPoint: .top, endPoint: .bottom)

            if expose < 1 {
                mainLayout
                    .opacity(1 - expose)
                    .scaleEffect(1 - 0.03 * expose)
                    .allowsHitTesting(expose == 0)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if expose > 0 {
                ExposeView()
                    .opacity(expose)
                    .scaleEffect(1.04 - 0.04 * expose)
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }

            overlays
            PaneDragGhost()
        }
        .coordinateSpace(.named(Self.space))
        .environment(\.uiFontFamily, model.uiFontFamily)
        .overlayPreferenceValue(TooltipKey.self) { TooltipLayer(requests: $0, theme: theme) }
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.den, value: model.overview)
        .animation(.den, value: model.tabStyle)
        .animation(.den, value: model.density)
        .animation(.easeInOut(duration: 0.25), value: model.effectiveInterfaceStyle)
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .animation(.easeOut(duration: 0.12), value: model.leaderPending)
        .animation(.easeOut(duration: 0.18), value: model.loginRequest)
        .animation(.easeOut(duration: 0.18), value: model.whatsNew)
        .animation(.easeInOut(duration: 0.25), value: theme)
    }

    /// The normal window: tab bar or sidebar around the active tab.
    @ViewBuilder
    private var mainLayout: some View {
        let surfaces = model.surfaces
        let pad = model.density.outerPadding
        Group {
            if model.tabStyle == .vertical {
                let collapsed = model.sidebarCollapsed
                HStack(spacing: 0) {
                    if !collapsed {
                        Sidebar()
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    VStack(spacing: 0) {
                        if collapsed {
                            CollapsedSidebarBar()
                                .transition(.opacity)
                        }
                        content
                            .padding(.top, collapsed ? 0 : pad)
                            .padding(.bottom, pad)
                            .padding(.leading, collapsed ? pad : 0)
                            .padding(.trailing, pad)
                            .overlay(alignment: .leading) {
                                // Compact density: a hairline instead of a gap.
                                if model.density == .compact, !collapsed { surfaces.hairline.frame(width: 1) }
                            }
                    }
                }
                .animation(.den, value: collapsed)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                VStack(spacing: 0) {
                    TitleBar().zIndex(1)
                    content
                        .padding(.horizontal, pad)
                        .padding(.bottom, pad)
                        .padding(.top, 2 * min(model.overviewLevel, 1))
                        .overlay(alignment: .top) {
                            if model.density == .compact { surfaces.hairline.frame(height: 1) }
                        }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let tab = model.activeLayout {
                Group {
                    if let zoomed = model.zoomedPane, tab.root.contains(zoomed) {
                        PaneCard(pane: zoomed, tab: tab.id)
                            .transition(.scale(scale: 0.97).combined(with: .opacity))
                    } else {
                        SplitTreeView(node: tab.root, tab: tab.id)
                    }
                }
                .id(tab.id)
                .transition(.opacity)
            } else {
                placeholder
            }
        }
        .animation(.denFast, value: model.activeTab)
        .animation(.den, value: model.zoomedPane)
        .animation(.den, value: model.activeLayout?.root)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if model.overview == .peek { withAnimation(.den) { model.overview = .none } }
        })
    }

    @ViewBuilder
    private var placeholder: some View {
        let theme = model.theme
        RoundedRectangle(cornerRadius: model.density.cornerRadius, style: .continuous)
            .fill(model.surfaces.card)
            .overlay {
                if let problem = model.currentHostProblem {
                    VStack(spacing: 10) {
                        Text(model.hostLabel(.remote(problem.host))).uiFont(size: 13, weight: .semibold)
                        Text(problem.message).uiFont(size: 12).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
                        HStack {
                            if model.remoteStates[problem.host] == .needsLogin {
                                Button("Log In…") { model.requestLogin(problem.host) }
                            } else {
                                Button("Reconnect Now") { model.connectRemote(problem.host, reveal: true) }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 420)
                } else {
                    localPlaceholder
                }
            }
    }

    @ViewBuilder
    private var localPlaceholder: some View {
        let theme = model.theme
        switch model.connectionState {
        case .connecting, .connected:
            ProgressView().controlSize(.small)
        case .disconnected(let reason):
            VStack(spacing: 10) {
                Text("Not connected to dend").uiFont(size: 13, weight: .semibold)
                Text(reason).uiFont(size: 12).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
                if model.outdatedDends.contains(.local) {
                    Button("Restart dend") { Task { await model.restartOutdatedDends() } }
                    Text("This ends the sessions it's running.").uiFont(size: 11).foregroundStyle(theme.tertiaryText)
                } else {
                    Button("Reconnect") { Task { await model.connect() } }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        let dismissible = model.showSessionMenu || model.palette != nil
        if dismissible {
            // Clicking anywhere outside a menu closes it.
            Color.black.opacity(0.001)
                .onTapGesture {
                    model.showSessionMenu = false
                    model.previewTheme = nil
                    model.palette = nil
                }
        }

        if model.showSessionMenu {
            SessionMenu()
                .padding(.leading, model.tabStyle == .vertical ? 14 : TitleBar.leadingInset + 2)
                .padding(.top, TitleBar.height - 2)
                .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity), removal: .opacity))
        }

        if model.palette != nil {
            // Centered under the title bar, as in Superlogical's Rex.
            CommandPalette()
                .padding(.top, TitleBar.height + 4)
                .frame(maxWidth: .infinity, alignment: .top)
                .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity), removal: .opacity))
        }

        if let request = model.loginRequest {
            Color.black.opacity(0.18)
                .onTapGesture { model.cancelLogin() }
                .transition(.opacity)
            LoginForm(request: request)
                .id("\(request.host)-\(request.message ?? "")")
                .padding(.top, TitleBar.height + 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }

        if let whatsNew = model.whatsNew {
            Color.black.opacity(0.18)
                .onTapGesture { model.dismissWhatsNew() }
                .transition(.opacity)
            WhatsNewPanel(whatsNew: whatsNew)
                .padding(.top, TitleBar.height + 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }

        if model.leaderPending {
            VStack {
                Spacer()
                TooltipBubble(text: "Leader", keys: [model.config.leader.keycaps], theme: model.theme)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .offset(y: 4)))
        }

        if let toast = model.toast {
            let position = model.config.toastPosition
            VStack {
                if !position.isTop {
                    Spacer()
                }
                ToastView(toast: toast, theme: model.theme, style: model.effectiveInterfaceStyle,
                          fontFamily: model.uiFontFamily, fontSize: model.uiFontSize - 1,
                          onAction: { model.performToastAction($0) })
                    .frame(maxWidth: .infinity, alignment: position.frameAlignment)
                    // Floats over the panes with the same inset from every
                    // edge it hugs; top pills start below the tab bar.
                    .padding(.horizontal, Self.toastInset)
                    .padding(position.isTop ? .top : .bottom, position.isTop ? TitleBar.height + Self.toastInset : Self.toastInset)
                if position.isTop {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            // Plain confirmations let clicks pass through to the terminal;
            // button toasts need to receive them.
            .allowsHitTesting(!toast.actions.isEmpty)
            .id(toast.id)
            .transition(.opacity.combined(with: .offset(y: position.isTop ? -6 : 6)))
        }

        if let error = model.lastError {
            VStack {
                Spacer()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).uiFont(size: 12).fixedSize(horizontal: false, vertical: true)
                    Button { model.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(12)
                .frame(maxWidth: 520)
                .background(MenuSurface(theme: model.theme))
                .padding(18)
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private extension ToastPosition {
    /// Horizontal placement of the pill within its full-width row.
    var frameAlignment: Alignment {
        switch self {
        case .topLeft, .bottomLeft: .leading
        case .topCenter, .bottomCenter: .center
        case .topRight, .bottomRight: .trailing
        }
    }
}
