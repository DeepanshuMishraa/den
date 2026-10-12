import AppKit
import Foundation
import Sparkle

/// Sparkle updates with Den's toast as the UI instead of Sparkle's windows:
/// "Checking for updates…" while the feed loads, a progress toast for the
/// download, and a persistent toast with a Restart button once the update is
/// ready to install.
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
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        self.driver = driver
        self.updater = updater
        do {
            try updater.start()
        } catch {
            NSLog("Den updates unavailable: %@", error.localizedDescription)
            self.driver = nil
            self.updater = nil
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

/// SPUUserDriver that narrates the update through toasts. Every method runs
/// on the main thread.
@MainActor
private final class ToastUserDriver: NSObject, SPUUserDriver {
    private weak var model: AppModel?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var lastProgressPush = Date.distantPast

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Check

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        // Automatic checks are off (`SUEnableAutomaticChecks = NO`), so this
        // only matters if that ever changes: allow checks, decline profiling.
        SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // Persistent: a plain toast vanishes after ~1.6s, leaving a gap with
        // nothing on screen while the feed loads, which reads as "checking
        // then nothing". The progress toast stays until the check resolves.
        model?.showUpdateProgress("Checking for updates…", progress: nil)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        let version = appcastItem.displayVersionString
        if appcastItem.isInformationOnlyUpdate {
            if let url = appcastItem.infoURL {
                model?.showActionToast("Den \(version) is available — download it from GitHub",
                                       actions: [("Open", { NSWorkspace.shared.open(url) })])
            } else {
                model?.showToast("Den \(version) is available")
            }
            return .dismiss
        }
        resetProgress()
        model?.showUpdateProgress("Downloading Den \(version)…", progress: 0)
        // Straight to downloading: the user asked to check, the feed is ours.
        return .install
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error) async {
        // Automatic checks are off (`SUEnableAutomaticChecks = NO`), so any
        // call here follows a manual check. Always toast: relying on
        // `SPUNoUpdateFoundUserInitiatedKey` left users staring at a vanished
        // "Checking…" toast when the flag was absent.
        NSLog("Den: no update found (%@)", error.localizedDescription)
        model?.showToast("No updates available")
    }

    func showUpdaterError(_ error: Error) async {
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
        model?.showUpdateProgress(nil, progress: progress)
    }

    func showDownloadDidStartExtractingUpdate() {
        model?.showUpdateProgress("Installing update…", progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model?.showUpdateProgress("Installing update…", progress: progress)
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        // Wait for the Restart tap. Dismissing means "later": Sparkle keeps
        // the staged update and installs it on the next quit.
        await withCheckedContinuation { continuation in
            model?.showActionToast("Update ready — restart Den to finish",
                                   actions: [
                                       ("Restart", { continuation.resume(returning: .install) }),
                                       ("Later", { continuation.resume(returning: .dismiss) }),
                                   ])
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        model?.showToast("Installing update…")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        model?.dismissToast()
    }

    func dismissUpdateInstallation() {
        model?.dismissToast()
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
}
