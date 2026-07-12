# Hyperfocus

**Blur and desaturate your background windows. Keep only what matters sharp.**

Hyperfocus is a lightweight macOS menu-bar utility that dims, desaturates, and blurs every window except the one you're working in. It cuts visual noise so you can think, write, and present without distraction — without melting your GPU or demanding permissions you'd rather not grant.

Built for deep work, screen sharing, and a calmer desktop.

---

## Install

### Homebrew (recommended)

```bash
brew install --cask hyperfocus
```

### Direct download

Grab the latest `.dmg` from the [releases page](https://github.com/user/hyperfocus/releases), drag **Hyperfocus** into `/Applications`, and launch it. The app lives in your menu bar — no Dock icon.

Requires **macOS 12.3** (Monterey) or newer.

---

## Quick start

1. Launch Hyperfocus. A focus icon appears in the menu bar.
2. Click the icon → **Turn On Focus**. Your active window stays sharp; everything behind it recedes.
3. Fine-tune in **Settings**:
   - Studio dim color, blur radius, and saturation
   - Enable or disable the effect per display
   - An app exclusion list for apps that should suspend the effect when frontmost
4. Toggle from the menu bar or enable shake-to-toggle in Settings.

That's it. **Zero permissions** required to start.

---

## Features

### Free - Studio mode

Studio works without Screen Recording permission:

- **Dim** background windows with a solid-color overlay
- Rounded cutout keeps the active window clear and live
- Enable or disable the effect per display
- App exclusion list for frontmost apps
- Menu-bar toggle, optional shake-to-toggle, and launch at login

### Pro - Deep mode

Deep mode is available during the seven-day trial and after Pro activation.

- **Live blur** of background windows via ScreenCaptureKit
- Adjustable blur radius and saturation
- A still frame is shown before the live stream starts

Deep mode requires Screen Recording permission, requested only when you enable it.
The app uses the permission solely to render the on-device blur effect.
Nothing is recorded, transmitted, or stored.

**[Buy Pro on Gumroad →](https://hyperfocus.gumroad.com/l/pro)**

---

## Why Hyperfocus

Hyperfocus uses a quarter-resolution ScreenCaptureKit stream and a fused Metal blur and desaturation kernel in Deep mode.
Studio mode uses a lightweight, permission-free dim overlay.

No accounts. No data collection. No telemetry. Just focus.

---

## License & distribution

Hyperfocus is distributed direct via Gumroad and Homebrew. Pro is a one-time purchase validated locally — once unlocked, it works offline forever.
