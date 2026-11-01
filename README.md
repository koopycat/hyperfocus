# Hyperfocus

**Blur and desaturate your background windows. Keep only what matters sharp.**

Hyperfocus is a lightweight macOS menu-bar utility that dims, desaturates, and blurs every window except the one you're working in. It cuts visual noise so you can think, write, and present without distraction — without melting your GPU or demanding permissions you'd rather not grant.

Built for deep work, screen sharing, and a calmer desktop.

---

## Install

### Homebrew (recommended)

The cask ships from the shared Koopycat tap:

```bash
brew tap koopycat/tap
brew install --cask koopycat/tap/hyperfocus
```

On first install Homebrew asks you to trust the tap (or run `brew trust --tap koopycat/tap`).

### Direct download

Grab the latest `.dmg` from the [releases page](https://github.com/koopycat/hyperfocus/releases), drag **Hyperfocus** into `/Applications`, and launch it. The app lives in your menu bar — no Dock icon.

Requires **macOS 12.3** (Monterey) or newer.

---

## Quick start

1. Launch Hyperfocus. A focus icon appears in the menu bar.
2. Click the icon → **Turn On Focus**. Your active window stays sharp; everything behind it recedes.
3. Fine-tune in **Settings**:
   - Choose Studio or Deep from the mode selector above every tab; Effects shows only controls used by that mode, preserving each mode's saved values
   - Studio dim color and saturation
   - Deep-mode Focus filters, blur radius, filter saturation, and background updates
   - Presentation filters for polished screen sharing and recordings
   - Enable or disable the effect per display
   - An app exclusion list for apps that should suspend the effect when frontmost
4. Toggle from the menu bar.

That's it. **Zero permissions** required to start.

The unused Groups editor has been removed. Use **Exclusions** to pause the effect for a frontmost app; exclusion and Studio color changes apply immediately, and imported settings refresh the open controls.

---

## Features

### Studio mode

Studio works without Screen Recording permission:

- **Dim** background windows with a solid-color overlay
- Rounded cutout keeps the active window clear and live
- Enable or disable the effect per display
- App exclusion list for frontmost apps
- Menu-bar toggle and launch at login

### Deep mode

- **Focus filters**: Deep, Ink, Fog, Ember, Vignette, and Paper keep background text unreadable while changing the mood of the workspace
- **Presentation filters**: Frost and Bokeh prioritize a polished shared screen when visual appeal matters more than maximal attentional austerity
- Adjustable blur radius and filter saturation, with a protected minimum blur so background text stays unreadable
- Saturation is unavailable when a filter fully replaces source colors, such as Ember; the disabled control explains why
- **Background updates**: Live follows changes, Settled coalesces them, and Frozen holds one calm still frame
- **Capture Rate Limit** sets the maximum capture FPS, not a guaranteed visible update rate. Power and thermal limits may reduce it further; Frozen manages capture automatically and disables this slider
- A filtered still frame is shown before the live stream starts

Deep mode requires Screen Recording permission, requested only when you enable it.
The app uses the permission solely to render the on-device blur effect.
Nothing is recorded, transmitted, or stored.

---

## Why Hyperfocus

Hyperfocus uses a quarter-resolution ScreenCaptureKit stream and a fused Metal blur and desaturation kernel in Deep mode.
Studio mode uses a lightweight, permission-free dim overlay.

No accounts. No data collection. No telemetry. Just focus.

---

## License & distribution

Hyperfocus is free and open source, distributed via [GitHub Releases](https://github.com/koopycat/hyperfocus/releases) and Homebrew. All modes — Studio and Deep — are included with no trial, no license, and no subscription. No accounts. No data collection. No telemetry.

Maintainers: see [`docs/RELEASING.md`](docs/RELEASING.md) for the automated signed, notarized, and Homebrew-published release process.
