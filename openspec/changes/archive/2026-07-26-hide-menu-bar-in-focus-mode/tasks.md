## 1. Focus Presentation State

- [x] 1.1 Replace fullscreen-style auto-hide with paired `.hideMenuBar` and `.hideDock` presentation options while preserving the existing exact snapshot and restoration behavior.
- [x] 1.2 Keep complete menu bar hiding active through temporary overlay suppression, foreground-application changes, and display reconfiguration without replacing the original snapshot, and restore prior presentation options on focus deactivation and normal termination.
- [x] 1.3 Place each click-through focus overlay at `.statusBar` level so it reliably covers the system-owned menu bar while leaving higher-priority system UI unobstructed.

## 2. Deep Mode Regression

- [x] 2.1 Compare full-display Deep capture with and without ScreenCaptureKit menu bar exclusion and retain the continuous full-display approach that produces no transparent top strip.

## 3. Verification

- [x] 3.1 Build Hyperfocus and validate the OpenSpec change.
- [x] 3.2 Reproduce the original Deep-mode failure end to end and verify no Apple logo, menu titles, status items, clock, background, or blurred copy remains with the pointer away from the top edge.
- [x] 3.3 Move the pointer to the top edge on each connected display and verify the menu bar remains completely unavailable.
- [x] 3.4 Keep another application foreground and verify its menu bar remains covered while its focused window stays interactive.
- [x] 3.5 Verify focus deactivation and quitting while focused restore the prior presentation state.
