## Why

The macOS menu bar remains visible as a blurred ghost while focus mode is active because fullscreen-style auto-hide can preserve its last captured pixels and allows the real menu bar to return at the top edge.
Focus mode should remove the menu bar completely, including Apple, status, and clock imagery.

## What Changes

- Make the macOS menu bar entirely unavailable whenever focus mode is active, including at the top screen edge and while another application is foreground.
- Temporarily hide the Dock as required by AppKit when the menu bar is made unavailable outside fullscreen mode.
- Cover the system menu-bar layer on each enabled display with the existing click-through focus overlay so foreground-application changes cannot make it visible again.
- Restore the user's prior application presentation behavior whenever focus mode is deactivated or Hyperfocus terminates.
- Preserve the existing menu bar status item and controls outside focus mode.

## Capabilities

### New Capabilities

<!-- None. -->

### Modified Capabilities

- `menu-bar-auto-hide`: Change focus behavior from top-edge-accessible auto-hide to complete menu bar removal, including exclusion from captured Deep-mode imagery, while restoring normal behavior on exit.

## Impact

- Focus activation, deactivation, and application shutdown handling in `Hyperfocus/AppCore/AppDelegate.swift`.
- Overlay window ordering in `Hyperfocus/OverlayEngine/OverlayWindowController.swift`.
- The existing `menu-bar-auto-hide` behavior contract and its regression scenarios.
- macOS application presentation options and window levels, including temporary Dock hiding required by AppKit; no new dependencies or public APIs.
