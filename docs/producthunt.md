# Hyperfocus — Product Hunt Launch Kit

Everything needed to ship Hyperfocus on Product Hunt.

---

## Tagline

> Blur + Desaturate background windows on macOS. Only your active window stays sharp. 3% GPU — not 50%.

---

## Description

**The problem**

Your Mac screen is a wall of tabs, chat windows, notes, and browser sessions. When you sit down to do deep work, everything screams for attention. Existing focus apps only go halfway:

- **HazeOver** dims the background, but the clutter is still readable and distracting.
- **Monocle** finally adds real blur, but users report it eating **50% GPU** on Apple Silicon and it costs ~$14.
- Most "focus" utilities either look ugly, demand scary permissions on first launch, or turn your laptop into a heater.

**The solution**

Hyperfocus is a native macOS utility that keeps only your active window sharp. Everything else fades, desaturates, or blurs — your choice.

- **Studio Mode:** dim + desaturate the background. No permissions, no battery hit, instant calm.
- **Deep Blur:** a frosted-glass blur rendered in Metal. The pipeline hashes each frame and only re-renders when the background changes — on a static screen Deep mode idles at about **0.1% CPU**, not 50%.
- **Presentation filters:** Frost and Bokeh polish the blurred background for clean screen shares and recordings.

**Why it’s different**

Most apps treat blur as a cosmetic extra. We treat it as a performance problem. Hyperfocus uses a downsampling + cached Metal pipeline so the blur is smooth and cheap. And we’re the only focus tool that pairs **blur + grayscale desaturation** — the combo your brain actually needs to stop noticing background noise.

Other details:

- No subscription and no trial — every mode is free.
- Studio Mode needs **zero permissions**.
- macOS 12.3+.
- Multi-display, Stage Manager, and Split View friendly.

---

## Maker Comment

Hey Product Hunt 👋

I built Hyperfocus because I love the *idea* of apps like Monocle and HazeOver, but my MacBook Pro sounded like a jet engine every time I turned on the blur. I kept asking: why does “focus” have to cost 50% GPU?

So I went the opposite direction. I started with a no-permission, dim-and-desaturate core (Studio Mode) that works in seconds. Then I rebuilt the blur pipeline from scratch using ScreenCaptureKit + Metal, downsampling and caching frames so Deep Blur stays around **3–5% GPU** on Apple Silicon. The result feels like a native macOS feature, not a heavy overlay.

What I learned: the biggest friction in this category isn’t price — it’s **permissions and performance**. If users trust the first launch, they’ll happily upgrade.

What’s next: Shortcuts + Focus Filters integration, a Raycast extension, Setapp exploration, and a small set of ADHD / accessibility presets (high contrast, reduced motion, larger focus borders).

Happy to answer questions in the comments!

— The Hyperfocus maker

---

## Suggested Launch Date

**Placeholder:** 2026-08-XX (final date TBD)

Pick a Tuesday–Thursday slot when the Product Hunt audience is most active. Avoid US holidays and major Apple announcement days.

---

## Topics / Tags

- macOS
- Productivity
- Focus
- ADHD
- Developer Tools
- Design

---

## Gallery Image Descriptions

Use these descriptions to create the Product Hunt gallery screenshots (1270×760 px recommended).

1. **Hero: messy desktop vs. focused desktop**
   A cluttered Mac desktop full of windows on the left, and the same desktop with Hyperfocus Deep Blur active on the right. Only the active window (e.g. Xcode or Figma) is sharp and colorful; everything else is softly blurred and desaturated.

2. **Menu bar switcher**
   The Hyperfocus menu bar dropdown showing the three modes: Studio, Deep Blur, Share. Highlight the “Deep Blur” option with a small GPU-usage badge (3–5%).

3. **Settings panel**
   A clean, native-looking settings window with sliders for dim intensity, desaturation amount, blur radius, and a list of per-app exceptions. Use macOS-style controls.

4. **Before / after screen sharing**
   Split image: top half shows a Zoom call screen-share with visible desktop clutter and chat windows; bottom half shows the Presentation filters hiding everything except the active presentation window.

5. **Permissions explainer**
   A friendly onboarding card that says “Studio Mode needs zero permissions” on one side, and a transparent Screen Recording request card on the other for Deep Blur.

---

## Optional First Comment Replies

If hunters ask about competitors:

> Great question. HazeOver is excellent for classic dimming, and Monocle proved people want real blur. Hyperfocus combines blur + desaturation and keeps GPU usage low enough that you can leave it on all day.

If hunters ask about privacy:

> Hyperfocus is local-first. Screen captures are processed on-device and never leave your Mac. Studio Mode needs no permissions at all.

---

## Quick Links to Include

- Website / landing page: `https://koopycat.github.io/hyperfocus/`
- Free download: `https://koopycat.github.io/hyperfocus/#download`
- GitHub: `https://github.com/koopycat/hyperfocus` (releases + source)
