import Cocoa

/// Manages overlay windows across all connected displays
final class DisplayManager {
    private var overlays: [CGDirectDisplayID: OverlayWindowController] = [:]

    init() {
        registerForDisplayChanges()
    }

    func configureForAllScreens() {
        for screen in NSScreen.screens {
            let displayID = screen.displayID
            if overlays[displayID] == nil {
                let overlay = OverlayWindowController(screen: screen)
                overlays[displayID] = overlay
            }
        }
    }

    func removeAllOverlays() {
        for (_, overlay) in overlays {
            overlay.orderOut()
        }
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
        // Handle display add/remove/resize
        let currentIDs = Set(NSScreen.screens.map { $0.displayID })
        let existingIDs = Set(overlays.keys)

        // Remove overlays for disconnected displays
        for id in existingIDs.subtracting(currentIDs) {
            overlays[id]?.orderOut()
            overlays.removeValue(forKey: id)
        }

        // Add overlays for newly connected displays
        for id in currentIDs.subtracting(existingIDs) {
            if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                overlays[id] = OverlayWindowController(screen: screen)
            }
        }

        // Overlays on remaining displays auto-adjust via their screen.frame binding
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

// MARK: - NSScreen DisplayID Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
