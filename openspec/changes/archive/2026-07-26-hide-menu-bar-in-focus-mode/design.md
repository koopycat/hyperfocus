## Context

Hyperfocus runs as an accessory application with an `NSStatusItem` and drives focus-mode lifecycle from `AppDelegate`.
The current implementation applies fullscreen-style menu bar auto-hide.
That behavior does not satisfy the requested focus experience: it can leave blurred Apple, menu, status, and clock imagery in the Deep overlay, and moving the pointer to the top edge reveals the real menu bar.
The required behavior is stricter: no menu bar content or background may remain visible while focus mode is active.

## Goals / Non-Goals

**Goals:**

- Make the macOS menu bar entirely unavailable throughout an active focus session.
- Keep it unavailable when the pointer reaches the top edge or another application is foreground.
- Restore the exact application presentation options that were active before focus mode.
- Keep the focused application interactive while its menu bar is covered.
- Apply the behavior consistently across focus lifecycle paths and enabled connected displays.

**Non-Goals:**

- Providing top-edge access to the menu bar during focus mode.
- Keeping the Dock visible while AppKit requires it to be hidden with the menu bar.
- Adding a setting for menu bar visibility.
- Changing the status item's appearance or menu outside focus mode.
- Changing ScreenCaptureKit capture bounds or removing the top screen area from Deep mode.

## Decisions

### Use `.hideMenuBar` with `.hideDock`

Add `.hideMenuBar` and `.hideDock` to `NSApp.presentationOptions` when focus activates.
AppKit defines these options as making the menu bar and Dock entirely unavailable and requires the two hide options to be paired outside fullscreen presentation.
This native presentation combination keeps the menu bar gone even when the pointer reaches the top edge.
Empirical end-to-end testing also confirms that changing from auto-hide to complete hide removes the blurred menu bar ghost without cropping Deep-mode capture content.

`.autoHideMenuBar` was rejected because it deliberately reveals the menu bar at the top edge and, in the observed failure, left menu bar imagery visible in the overlay.
An overlay-only solution was rejected because it can leave interactive or captured system UI underneath and does not express the intended application presentation state.
`NSMenu.setMenuBarVisible` was rejected because presentation options provide the focus-scoped behavior and an exact restoration point.

### Keep full-display Deep capture unchanged

Do not set `SCContentFilter.includeMenuBar` to `false`.
End-to-end comparison showed that excluding the menu bar from ScreenCaptureKit produced a transparent top strip in the full-display overlay, revealing the desktop wallpaper rather than creating a seamless distraction-free area.
With `.hideMenuBar` active before Deep capture starts, leaving the full-display filter unchanged produces a continuous blurred surface with no menu bar content.

### Snapshot and restore the prior presentation options

Capture `NSApp.presentationOptions` before the first focus activation, then apply the captured options plus `.hideMenuBar` and `.hideDock`.
On focus deactivation or application termination, restore the captured option set exactly and clear the snapshot.
The enable helper remains idempotent with respect to the snapshot but always reapplies the derived hidden option set, so a display reconfiguration cannot leave presentation options reset while focus remains active.
Repeated restoration is harmless after the snapshot is cleared.

Because AppKit presentation options are controlled by the active foreground application, Hyperfocus cannot rely on them after focus returns to another app.
Focus overlays therefore use `NSWindow.Level.statusBar`, one level above the menu bar, and remain click-through, covering the system menu bar with the same focused visual surface regardless of foreground application.
Using `NSWindow.Level.mainMenu` was rejected because tying the system menu-bar level does not guarantee ordering above the system-owned window.
Using `NSWindow.Level.screenSaver` was rejected because it would unnecessarily cover higher-priority system UI.
The presentation options still suppress the menu bar during activation and prevent it from being captured into the initial Deep-mode frame.

### Keep hiding tied to focus state

Apply the hidden state at the start of `activateFocus()` and restore it in `deactivateFocus()`.
Also restore it from `applicationWillTerminate` as defensive cleanup.
The menu bar remains unavailable when overlays are temporarily suppressed for an excluded app, window drag, pointer movement, or display reconfiguration because focus mode itself remains active.

## Risks / Trade-offs

- [The Hyperfocus status item is inaccessible while focus is active] -> Users must leave focus through the configured global shortcut; this follows directly from the requirement that all menu bar content be gone.
- [AppKit requires the Dock to be hidden with the menu bar] -> Pair `.hideDock` with `.hideMenuBar` and restore the exact prior options on exit.
- [A capture begun before the presentation transition retains stale menu bar pixels] -> Apply presentation options before configuring overlays and starting the Deep capture session.
- [A lifecycle path fails to restore the prior presentation options] -> Centralize restoration and call it from both focus deactivation and normal termination.
- [An overlay tied with the menu-bar window renders underneath it] -> Use `.statusBar` rather than `.mainMenu`, retain `ignoresMouseEvents`, and leave higher-priority system-modal window levels unobstructed.
