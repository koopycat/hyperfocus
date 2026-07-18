# Hyperfocus - Project Analysis & Deep-Mode GPU Report (Final)

## 1. Project Overview

**Hyperfocus** is a macOS menu-bar utility (~3,300 LOC Swift/AppKit/Metal) that dims/blurs everything except the focused window.

| Component | Files | Role |
|---|---|---|
| `AppCore` | AppDelegate, MenuBarController, SettingsView, Onboarding | state machine, UserDefaults KVO, menu UI |
| `OverlayEngine` | DisplayManager, OverlayWindowController, ActiveWindowTracker, MouseTracker | per-display overlay windows, cutout tracking |
| `RenderPipeline` | BlurEngine, MetalBlurRenderer, BlurDesatShaders.metal | ScreenCaptureKit capture + Metal blur (Deep mode) |

Two modes: **Studio** (free, permission-free dim overlay) and **Deep** (live SCK capture at 1/4 res --> MPS Gaussian blur + BT.709 desaturation --> `CAMetalLayer`).

Market context: the #1 competitor complaint is **GPU burn** ("Monocle uses >50% GPU on M4 Pro"). Performance is the differentiator.

## 2. Weak Spots Found (Deep mode / GPU)

| # | Severity | Issue |
|---|---|---|
| 1 | **P0 correctness + perf** | Uncommitted CAMetalLayer path never set `drawableSize`. Proved with a live test: drawable is full-display while the blit writes only the quarter-res capture at origin (0,0) --> blurred image fills **6.2%** of the screen, the rest is stale garbage, and every drawable wastes **16x memory**. |
| 2 | **P0 energy** | `deactivateFocus()` never called `blurEngine.detachAll()`. Turning Hyperfocus **off** left all capture streams + Metal rendering running forever into hidden windows. |
| 3 | **P1 energy** | Rendering continued while overlays were invisible: window drags, mouse-leave, excluded-app frontmost. GPU burned for pixels nobody sees. |
| 4 | **P1 energy (the big one)** | Every captured frame was blurred **and presented** at 10-30 FPS even when nothing changed. The present forces WindowServer to recomposite the full screen every frame --> this dominates the GPU cost, not the quarter-res blur. |
| 5 | P2 perf | Extra full-res pass: desaturate wrote to an output texture, then a blit copied it into the drawable. |
| 6 | Bug | `blurFPS` unread on fresh installs: `integer(forKey:)` returns 0 --> clamped to **1 FPS**. |
| 7 | Robustness | `renderer == nil` left the display permanently stuck in `renderingDisplays`; `fatalError` on texture allocation failure. |
| 8 | Latency leak | `configureMetalLayer` stacked a new CAMetalLayer on every re-attach and deleted `contentLayer`, which silently dropped the boot still frame and broke Deep->Studio switching. |
| 9 | Latency | `attach` did **three** sequential `SCShareableContent.current` fetches (permission, screenshot, stream). |
| 10 | Dead code | `StripOverlay` was instantiated per display but only ever `.hide()`n. |
| 11 | UX | Dragging the blur slider recreated `MPSImageGaussianBlur` on every 1-px tick. |

## 3. All Fixes Implemented

### Core Deep-mode fixes (from first pass)

**`OverlayWindowController.swift`**
- `configureMetalLayer(device:drawableSize:)` sets the drawable to the quarter-res capture size so CA upscales for free during compositing (fix #1), idempotent re-attach (fix #8), `contentLayer` kept for the boot still frame, Studio switch tears the Metal layer down.
- New `cutoutInCapturePixels()` converts the cutout to texture space for the hash skip rect.

**`BlurDesatShaders.metal`** - new `frameHash` kernel: single-threadgroup FNV hash over a stride-2 sample grid, excluding the active-window cutout rect (typing in the focused window is not a "background change").

**`MetalBlurRenderer.swift`** - two-phase pipeline: hash pass; only if changed -> MPS blur --> desaturate writes **directly into the drawable** (blit pass eliminated, fix #5). All state confined to one serial queue; `fatalError` replaced with frame-drop; `clearFrameState` on detach; `debugStats` counters (fixes #3, #4, #7).

**`BlurEngine.swift`** - `setRenderingPaused()`, `framesPerSecond` 0->10 default fix, passes drawableSize + skip-rect + cache key, renderer-nil no longer stalls (fixes #2 wiring, #6, #7).

**`AppDelegate.swift`** - `deactivateFocus()` now calls `detachAll()` (fix #2); `updateRenderingPause()` derives pause state from one place (drag / mouse-outside / excluded-app) so pause/resume pairs cannot drift (fix #3).

### Additional recommendations implemented

**`BlurEngine.swift` - SCShareableContent sharing (fix #9)**
The attach flow now fetches `SCShareableContent.current` once and passes it to both the boot screenshot and the live stream. The overlay window is already on-screen before this fetch (AppDelegate shows it first), so the overlay's own windowNumber is visible and can be excluded reliably. This cuts the activation fetch count from 3 to 1-2.

**`BlurEngine.swift` + `AppDelegate.swift` - adaptive FPS (new)**
- `effectiveFramesPerSecond` caps the user-selected rate under system stress:
  - Low-power mode: max 10 FPS
  - Thermal `.fair`: max 15 FPS
  - Thermal `.serious`/`.critical`: max 5 FPS
- Observes `ProcessInfo.thermalStateDidChangeNotification` and the raw `NSProcessInfoPowerStateDidChangeNotification` string.
- Posts `BlurEngine.thermalThrottlingChanged` when the effective rate changes; AppDelegate restarts the Deep session (same path as `blurFPS` changes) so each new stream runs at the correct rate.

**`MetalBlurRenderer.swift` - quantize MPS sigma (fix #11)**
Sigma is rounded to 0.5 steps. Across the full 0-48 display-pixel radius range this produces ~12 distinct filters instead of ~48, eliminating per-tick allocation while the user drags the slider. Visual difference is imperceptible.

**Dead code removal (fix #10)**
- Deleted `Hyperfocus/OverlayEngine/StripOverlay.swift`.
- Removed `stripOverlays` from `DisplayManager` and all `stripOverlay`/`allStripOverlays` references from `AppDelegate`.
- Removed the now-missing file reference from `Hyperfocus.xcodeproj/project.pbxproj`.

**Test harness (new)**
Moved the end-to-end test into `tests/RendererHarness/` with a `build.sh` script. It compiles the real `MetalBlurRenderer` plus the Metal shader into a tiny `.app`, drives the pipeline with synthetic frames, and asserts the change-detection and drawable behavior. This is especially important because the CLI build compiles Metal shaders at runtime and skips API validation.

## 4. Measured Results (harness driving the real renderer + real CAMetalLayer)

```
PASS: drawable size 640x360 == capture 640x360      (was: 2560x1440, 6.2% fill)
PASS: first frame rendered / identical skipped / cutout-only change skipped
PASS: background change rendered / settings change forces render
PASS: clearFrameState forces render / 50-frame static burst fully skipped

changed frame : 16.70 ms  (hash+blur+desat+present, 5K quarter-res worst case)
static frame  :  0.78 ms  (hash only)
reduction     : 21x less work per static frame
```

Net effect on a static desktop at 10 FPS: Deep-mode GPU cost collapses to SCK capture + one tiny hash pass per frame; no blur, no present, no WindowServer recomposite. This directly addresses the "Monocle melts my M4 Pro" complaint.

## 5. Verification Run

- `scripts/build.sh` --> **BUILD SUCCEEDED**
- `xcodebuild -project Hyperfocus.xcodeproj -scheme Hyperfocus -configuration Debug build` --> **BUILD SUCCEEDED**
- `tests/RendererHarness/build.sh` --> **ALL PASS**
- App launch smoke test --> process alive, 0% CPU idle

## 6. Remaining Watch Items (not changed)

- **Studio mode `backgroundFilters`**: full-screen `CIColorControls` backdrop filter still runs in WindowServer whenever saturation < 1. It is a standard vibrancy mechanism, but keep an eye on GPU reports. If it becomes a problem, the fix would be to move Studio desaturation into a Metal dim pass as well.
- **Real-device powermetrics**: `powermetrics --samplers gpu_power` on a machine with Screen Recording permission granted would give the final end-to-end GPU% numbers. This environment cannot grant that permission headlessly.

All changes are uncommitted on your working tree. Nothing was committed.
