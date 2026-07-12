import Cocoa

/// Manages overlay windows across all connected displays.
/// Deep mode uses OverlayWindowController (single window + captured image + mask).
final class DisplayManager {
    private var overlays: [CGDirectDisplayID: OverlayWindowController] = [:]

    init() {
        registerForDisplayChanges()
    }

    func configureForAllScreens() {
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if overlays[displayID] == nil {
                overlays[displayID] = OverlayWindowController(screen: screen)
            }
        }
    }

    func removeAllOverlays() {
        for (_, overlay) in overlays { overlay.orderOut() }
        overlays.removeAll()
    }

    func overlay(for screen: NSScreen) -> OverlayWindowController? {
        return overlays[screen.displayID]
    }

    func overlay(for displayID: CGDirectDisplayID) -> OverlayWindowController? {
        return overlays[displayID]
    }

    func allOverlays() -> [OverlayWindowController] {
        return Array(overlays.values)
    }

    /// Display IDs are needed to match a filter-transition fade-out with the
    /// exact newly presented renderer frame for that display.
    func visibleOverlays() -> [(displayID: CGDirectDisplayID, overlay: OverlayWindowController)] {
        overlays.compactMap { displayID, overlay in
            overlay.isVisible ? (displayID, overlay) : nil
        }
    }

    // MARK: - Display Change Handling

    private func registerForDisplayChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)
    }

    @objc private func screenParametersChanged() {
        let currentIDs = Set(NSScreen.screens.map { $0.displayID })
        let existingIDs = Set(overlays.keys)

        // Remove for disconnected displays
        for id in existingIDs.subtracting(currentIDs) {
            overlays[id]?.orderOut()
            overlays.removeValue(forKey: id)
        }

        // Add for newly connected displays
        for id in currentIDs.subtracting(existingIDs) {
            if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                overlays[id] = OverlayWindowController(screen: screen)
            }
        }
    }
}

// MARK: - CGDisplay Callback

private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        // Trigger screen parameters update on main thread
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
}


