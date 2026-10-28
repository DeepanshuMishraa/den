import AppKit
import DenProtocol
import UserNotifications

/// Posts a system notification when a program finishes, fails or needs you
/// while Den isn't in front. Clicking one brings Den forward on that pane.
@MainActor
enum StatusNotifier {
    /// Focuses the pane a clicked notification came from.
    static var onOpen: ((PaneID) -> Void)?

    /// UNUserNotificationCenter needs an app bundle; `swift run` dev builds
    /// have none and would crash on first use.
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = delegate }
        return center
    }

    private static let delegate = Delegate()

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ sound: StatusChime.Sound, pane: PaneID, title: String, message: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        let fallback = switch sound {
        case .done: "Done"
        case .error: "Failed"
        case .blocked: "Needs your input"
        }
        content.body = message ?? fallback
        content.userInfo = ["pane": pane.raw.uuidString]
        // One notification per pane: a newer state replaces the older one.
        let request = UNNotificationRequest(identifier: pane.raw.uuidString, content: content, trigger: nil)
        center.add(request)
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard let raw = response.notification.request.content.userInfo["pane"] as? String,
                  let uuid = UUID(uuidString: raw) else { return }
            await MainActor.run {
                NSApp.activate()
                StatusNotifier.onOpen?(PaneID(uuid))
            }
        }
    }
}
