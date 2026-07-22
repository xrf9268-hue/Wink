import ApplicationServices
import Foundation

/// One row of the hold-to-show window picker: icon comes from the bundle
/// identifier (AppIconView), text from the AX title. Icons + titles only —
/// never thumbnails (Screen Recording stays off the permission list, the
/// #352 red line).
struct WindowPickerItem: Identifiable, Equatable {
    var id: CGWindowID { windowID }
    let windowID: CGWindowID
    let title: String?
    let isMinimized: Bool
}

/// A resolved picker request for exactly one app's current-Space windows.
/// Holds the AX elements captured at listing time so a selection acts on the
/// same objects the user saw; a window that dies in between simply fails the
/// raise (the activation trio tolerates that).
@MainActor
struct WindowPickerSession {
    let bundleIdentifier: String
    let displayName: String
    let pid: pid_t
    let items: [WindowPickerItem]
    let elementsByWindowID: [CGWindowID: AXUIElement]
}
