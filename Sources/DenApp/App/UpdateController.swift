import AppKit
import Foundation
import Sparkle

/// Sparkle updates with Den's toast as the UI instead of Sparkle's windows:
/// "Checking for updates…" while the feed loads, "An update is available"
/// with a Download button, a progress toast for the download, and a
/// persistent toast with a Restart button once the update is ready.
///
/// Flow: Sparkle detects a new version (manual check, on-launch background
/// check, or the daily schedule) and `showUpdateFound` waits for the
/// Download tap; ✕ skips it until the next check. Then
/// `showReadyToInstallAndRelaunch` waits for the Restart tap. ✕ there means
/// later: Sparkle keeps the staged update and installs it on the next quit.
///
/// The app is ad-hoc signed, which is fine: update authenticity comes from
/// the EdDSA signature (`SUPublicEDKey`), not an Apple certificate. What
/// ad-hoc can't do is delta updates (full downloads only) and EdDSA key
/// rotation, so the private key in the `SPARKLE_PRIVATE_KEY` secret must be
/// kept. Also never sign with the hardened runtime (`-o runtime`): library
/// validation would stop an ad-hoc build from loading Sparkle.framework.
@MainActor
final class UpdateController: NSObject {
    private weak var model: AppModel?
    private var updater: SPUUpdater?
    // Strong: SPUUpdater only weakly references its driver and delegate.
    private var driver: ToastUserDriver?

    /// False for dev builds (a raw binary, not a .app bundle): Sparkle needs
    /// a bundle with an Info.plist feed URL and version to update.
    var isAvailable: Bool { updater != nil }

    init(model: AppModel) {
        self.model = model
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let driver = ToastUserDriver(model: model)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.driver = driver
        self.updater = updater
        do {
            try updater.start()
        } catch {
            NSLog("Den updates unavailable: %@", error.localizedDescription)
            self.driver = nil
            self.updater = nil
            return
        }
        // Detect on launch when automatic checks are on (Info.plist
        // SUEnableAutomaticChecks). Respects the user's preference: if they
        // turned checks off, this stays quiet.
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard let updater else {
            model?.showToast("Updates are only available in release builds")
            return
        }
        NSLog("Den: manual update check from %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        updater.checkForUpdates()
    }
}

// MARK: - Diagnostics

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        let check = switch updateCheck {
        case .updates: "manual"
        case .updatesInBackground: "background"
        case .updateInformation: "probe"
        @unknown default: "unknown"
        }
        NSLog("Den: %@ update check finished with error: %@", check, error.localizedDescription)
    }
}

/// SPUUserDriver that narrates the update through toasts. Every method runs
/// on the main thread.
@MainActor
private final class ToastUserDriver: NSObject, SPUUserDriver {
    private weak var model: AppModel?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var lastProgressPush = Date.distantPast
    /// What the toast is currently showing, so `showUpdateInFocus` (a second
    /// "Check for Updates" while one is in flight) can resurface it.
    private var phase: Phase = .idle
    /// The Download or Restart choice Sparkle is waiting on, if any.
    /// Single-resume guarded: re-showing the prompt (focus, toast churn)
    /// must not resume the same continuation twice.
    private var choiceContinuation: CheckedContinuation<SPUUserUpdateChoice, Never>?
    private var choiceResumed = false

    private enum Phase {
        case idle
        case checking
        case available(version: String)
        case downloading(message: String, progress: Double?)
        case extracting(progress: Double?)
        case ready
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Check

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        // Automatic checks are on (`SUEnableAutomaticChecks = YES`), so this
        // only matters if that ever changes: allow checks, decline profiling.
        SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // Persistent: a plain toast vanishes after ~1.6s, leaving a gap with
        // nothing on screen while the feed loads, which reads as "checking
        // then nothing". The progress toast stays until the check resolves.
        // (Only called for manual checks; background checks stay silent
        // until an update is actually found.)
        phase = .checking
        model?.showUpdateProgress("Checking for updates…", progress: nil)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        let version = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            phase = .idle
            if let url = appcastItem.infoURL {
                model?.showActionToast("Den \(version) is available — download it from GitHub",
                                       actions: [("Open", nil, { NSWorkspace.shared.open(url) })])
            } else {
                model?.showToast("Den \(version) is available")
            }
            return .dismiss
        }
        NSLog("Den: update found (%@, background=%@)", version, state.userInitiated ? "no" : "yes")
        phase = .available(version: version)
        let choice = await awaitChoice { self.showAvailablePrompt(version) }
        guard choice == .install else {
            phase = .idle
            return choice
        }
        resetProgress()
        let message = "Downloading Den \(version)…"
        phase = .downloading(message: message, progress: 0)
        model?.showUpdateProgress(message, progress: 0)
        return .install
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error) async {
        // Only called for user-initiated checks; background checks that find
        // nothing stay silent.
        phase = .idle
        NSLog("Den: no update found (%@)", error.localizedDescription)
        model?.showToast("No updates available")
    }

    func showUpdaterError(_ error: Error) async {
        phase = .idle
        NSLog("Den: update failed: %@", error.localizedDescription)
        model?.showToast("Update failed: \(error.localizedDescription)")
    }

    // MARK: Download and install

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        // These callbacks fire often; push to the view at most ~6 times/sec.
        let now = Date()
        guard now.timeIntervalSince(lastProgressPush) > 0.15 else { return }
        lastProgressPush = now
        if case .downloading(let message, _) = phase {
            phase = .downloading(message: message, progress: progress)
        }
        model?.showUpdateProgress(nil, progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting(progress: nil)
        model?.showUpdateProgress("Installing update…", progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .extracting(progress: progress)
        model?.showUpdateProgress("Installing update…", progress: progress)
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        // Wait for the Restart tap. Dismissing means "later": Sparkle keeps
        // the staged update and installs it on the next quit.
        phase = .ready
        let choice = await awaitChoice { self.showReadyPrompt() }
        // After "later" the staged update remains; stay idle so a later
        // check starts fresh.
        phase = .idle
        return choice
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        phase = .idle
        model?.showToast("Installing update…")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        phase = .idle
        model?.dismissToast()
    }

    func dismissUpdateInstallation() {
        // Sparkle aborting or finishing: don't leave a stale prompt behind,
        // and never leave a pending choice hanging (that would stall the
        // updater with no UI on screen).
        phase = .idle
        model?.dismissToast()
        resumeChoice(with: .dismiss)
    }

    func showUpdateInFocus() {
        // The user asked to check again while an update is already in
        // flight: resurface what we're showing instead of going silent.
        switch phase {
        case .idle:
            break
        case .checking:
            model?.showUpdateProgress("Checking for updates…", progress: nil)
        case .available(let version):
            showAvailablePrompt(version)
        case .downloading(let message, let progress):
            model?.showUpdateProgress(message, progress: progress)
        case .extracting(let progress):
            model?.showUpdateProgress("Installing update…", progress: progress)
        case .ready:
            // Re-show the prompt without minting a second continuation: the
            // buttons resume the one Sparkle is already waiting on.
            showReadyPrompt()
        }
    }

    // MARK: Prompts

    private func showAvailablePrompt(_ version: String) {
        model?.showActionToast("Den \(version) is available", tone: .notice(symbol: "arrow.down"),
                               actions: [("Download", "cmd+shift+u", { [weak self] in self?.resumeChoice(with: .install) })],
                               dismiss: ("cmd+shift+.", { [weak self] in self?.resumeChoice(with: .dismiss) }))
    }

    private func showReadyPrompt() {
        model?.showActionToast("Update ready — restart Den to finish", tone: .notice(symbol: "arrow.clockwise"),
                               actions: [("Restart", "cmd+shift+u", { [weak self] in self?.resumeChoice(with: .install) })],
                               dismiss: ("cmd+shift+.", { [weak self] in self?.resumeChoice(with: .dismiss) }))
    }

    /// Shows a prompt and waits for its Download/Restart or ✕.
    private func awaitChoice(_ prompt: @escaping () -> Void) async -> SPUUserUpdateChoice {
        choiceResumed = false
        let choice: SPUUserUpdateChoice = await withCheckedContinuation { continuation in
            choiceContinuation = continuation
            prompt()
        }
        choiceContinuation = nil
        return choice
    }

    // MARK: Helpers

    private var progress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    private func resetProgress() {
        expectedBytes = 0
        receivedBytes = 0
        lastProgressPush = .distantPast
    }

    /// Resume the pending choice exactly once. Late taps (a re-shown
    /// prompt racing dismissal) are ignored.
    private func resumeChoice(with choice: SPUUserUpdateChoice) {
        guard !choiceResumed, let continuation = choiceContinuation else { return }
        choiceResumed = true
        choiceContinuation = nil
        continuation.resume(returning: choice)
    }
}
