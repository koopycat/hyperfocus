# Hyperfocus Rescue-Analyse

>Status: Diagnose abgeschlossen, wartet auf Architektur-Entscheidung.
>Datum: 2026-07-12.

## TL;DR

Das Konzept ist gesund und am Markt validiert (HazeOver, Monocle, Hush, Fader).
Was kaputt ist, ist nicht das Konzept, sondern die Ausführung.
Die App hat **zwei konkurrierende Overlay-Systeme**, und der AppDelegate verkabelt das falsche.
Das gesamte entworfene High-Performance-System (4-Strip-Cutout + ScreenCaptureKit + Metal-Blur + Cache-State-Machine, ca. 950 Zeilen) ist praktisch **Totecode**.
Läuft stattdessen: ein Schnell-Prototyp namens `PerfectOverlay`, der den ganzen Bildschirm dimmt, **nicht blurred** und **kein Fenster ausschneidet**.

Beide genannten Symptome - "eckige Kanten" und "buggy Screencapture" - sind direkte Folgen dieser Fraktur.
Sie sind mit einer einzigen, konsequenten Architektur-Entscheidung behebbar.

---

## 1. Die Kern-Diagnose: Zwei parallele Welten

### Welt A - das entworfene System (in `design.md`, Tasks 2-4 abgehakt)

```
DisplayManager -> OverlayWindowController (4 Streifen pro Bildschirm)
              \-> EffectProvider (DimmingEffectProvider | ScreenCaptureKitBlurProvider)
                    \-> MetalBlurRenderer (Quarter-Res + Fused Kernel + Upscale)
                    \-> CachingEngine (Tile-Hashes, Dirty-Region, Memory-Pressure)
                    \-> StateMachine (off/idle/processing/systemAnimation)
ActiveWindowTracker -> CGRect des fokussierten Fensters
```

Das ist durchdacht, performant und entspricht genau dem, was design.md fordert.
Aber: **keines davon wird im laufenden Pfad benutzt.**

### Welt B - der laufende Prototyp (in `AppDelegate.activateFocus`)

```swift
perfectOverlays = NSScreen.screens.map { PerfectOverlay(screen: $0) }
// ... startCapture(displayID:) auf jedem Screen
```

`PerfectOverlay` ist ein einzelnes Vollbild-`NSWindow` mit einem `NSImageView`.
Es captured via `SCStream` den **kompletten Bildschirm in nativer Aufloesung** und zeigt das Bild mit `imageView.alphaValue = dimOpacity` an.
Die Eigenschaft `activeFrame` existiert, wird vom AppDelegate gesetzt - und **ignoriert** (Kommentar: "unused for now").

### Was das konkret bedeutet

- `DisplayManager` legt `OverlayWindowController`-Fenster an, die nie gezeigt oder positioniert werden - **verwaiste Fenster**.
- `EffectProvider = DimmingEffectProvider()` wird instanziiert, aber nie an ein Overlay `.attach()`t - **tot**.
- `ScreenCaptureKitBlurProvider`, `MetalBlurRenderer`, `CachingEngine`, `StateMachine`: **vollstaendig geschrieben, nirgendwo referenziert.**
- Der laufende Pfad (`PerfectOverlay`) macht **keinen Blur**, nur Alpha-Dimming, und schneidet **nichts aus** - das aktive Fenster wird mit abgedunkelt.

Das erklaert, warum die App "semi gut" aussieht aber das Kernversprechen ("scharfes Fenster, Rest blurred") nicht einloest.

---

## 2. Problem 1 - "Eckige Kanten passen nicht zum Rechteck-Konzept"

Hier muss man zwei Ebenen trennen.

### 2a. Das 4-Streifen-Cutout ist geometrisch unfähig fuer abgerundete Fenster

`OverlayWindowController` legt vier rechteckige Streifen rund um das Fenster.
Dazwischen entsteht ein rechteckiges Loch fuer das aktive Fenster.
Der Code compensiert mit `let pad: CGFloat = 8` ("8px padding for rounded corners").

macOS-Fenster haben aber ~10px **abgerundete** Ecken.
Daraus entstehen drei sichtbare Fehler:

1. **Scharfe quadratische Innenkanten** des Dim-Layers direkt an den Fensterkanten.
2. Ein sichtbarer **quadratischer Halo** (die 8px Luecke) rund um das Fenster.
3. An jeder Ecke eine **quadratische Kerbe**: dort, wo die abgerundete Fensterecke vom eckigen Overlay zurueckweicht, bleibt ein kleines Dreieck Desktop sichtbar, das weder zum Fenster noch zum Overlay passt.

**Vier Rechtecke koennen geometrisch kein abgerundetes Loch erzeugen.** Das ist keine Implementierungsschwaeche, das ist eine geometrische Unmoeglichkeit.
Das 8px-Padding ist kein Fix, es macht das Halo nur sichtbarer.

### 2b. Im laufenden Code passiert ueberhaupt kein Cutout

Weil `PerfectOverlay` laeuft und `activeFrame` ignoriert, wird der **ganze** Bildschirm abgedunkelt.
Das "Rechteck-Konzept" (Fenster bleibt scharf) findet schlicht nicht statt.
Wer den Effekt sieht, sieht also entweder gar keinen Cutout (Welt B) oder einen eckigen (Welt A, falls man den Pfad manuell testet).

### Fazit zu Problem 1

Der Cutout muss von vier Streifen auf **ein einziges Vollbild-Overlay mit Pfad-Maske** umgestellt werden (siehe Loesung).
Das ist der einzige Weg, abgerundete Ecken am Loch sauber abzubilden.

---

## 3. Problem 2 - "Screencapture mit Manipulation ist buggy"

Der laufende Capture-Pfad (`PerfectOverlay.stream(...)`) hat gleich mehrere Defekte:

### 3.1 Es gibt keinen Blur

Das Pro-Versprechen ist "real, soft cinematic blur".
`PerfectOverlay` zeigt aber nur den Roh-Frame mit Alpha-Transparenz (`imageView.alphaValue = dimOpacity`).
Der gesamte `MetalBlurRenderer` (Fused Gaussian + BT.709-Desaturation + bilinearer Upscale) wird nie aufgerufen.
Was der Nutzer fuer "Blur" haelt, ist nur ein halbtransparenter Schwarz-Overlay ueber einem Live-Bild.
Bei Bewegung flackert es, weil das unterliegende Bild nicht stabil gehalten, sondern live aktualisiert wird.

### 3.2 Pro-Frame CPU-Konvertierung

Jeder Frame macht: `CVPixelBufferLock` -> manuelles `CGContext` -> `makeImage` -> Main-Thread-Hop -> `NSImage`-Wrap -> `imageView.image =`.
Das passiert nativ in voller Aufloesung, ohne GPU.
Daraus resultieren Ruckeln, CPU-Spitzen und das "sehr buggy"-Gefuehl.
Der entworfene Pfad (CVMetalTextureCache zero-copy IOSurface) loest genau das - wird aber nicht genutzt.

### 3.3 Native statt Quarter-Res

Captured mit `cfg.width = display.width` (volle Aufloesung).
design.md Decision 2 sagt explizit 0.25x.
Voll-Res kostet ca. 15x mehr Textur-Bandbreite.

### 3.4 Capture-Feedback nicht ausgeschlossen

`SCContentFilter(display:, excludingWindows: [])` erfasst auch das eigene Overlay-Fenster.
Da das Overlay das abgedunkelte Bild zeigt und wiedererfasst wird, entsteht ein Rueckkopplungspfad, der das Bild pro Frame leicht veraendert - optisch ein subtiler Flimmer.
Der Fix: `excludingWindows: [overlayWindow]`.

### 3.5 Keine State-Machine, kein Caching

Jede Frame-Bewegung (auch Mauszeiger-Bewegung, die `showsCursor=false` uebrigens nur teilweise abfaengt) triggert eine neue Konvertierung.
Die `StateMachine` (.idle/.processing/.systemAnimation) und `CachingEngine` (Tile-Dirty-Region) sollen genau verhindern, dass bei stillstehendem Bild ueberhaupt GPU-Arbeit anfaellt.
Beide sind geschrieben und ungenutzt.

---

## 4. Kollateralschaeden (mitgefundene Tote Leitungen)

- `AppDelegate.activeAppDidChange` ist definiert, aber **nie als Observer registriert** (Workspace-Notification waehrend Focus laeuft wird nicht gehoert).
- Settings-Slider (`blurRadius`, `saturation`, `tintColor`) haben **keinen Effekt** - sie schreiben in `@AppStorage`, aber niemand liest sie an den Provider weiter.
- `excludedApps`, `appGroups`, `perDisplay` haben UI, werden aber **nicht angewendet**.
- `LicenseManager` existiert, ist nicht ans Toggle gebunden (Studio vs. Deep wird ignoriert).
- `ShakeDetector` wird nirgends instanziiert.
- `StateMachine.startAppActivationObservation()` wird nie aufgerufen.

Zusammengefasst: die App ist eine **polierte Huelle** (Onboarding, Settings, Menubar, Lizenz-Tab) auf einem Prototyp-Overlay, das das Falsche tut, waehrend der echte Motor ungenutzt in der Garage steht.

---

## 5. Die Rettung - drei Optionen

### Option 1 (Empfehlung): Single-Window + Pfad-Maske

**Ein** Vollbild-Overlay pro Bildschirm bei Level 19.
Seine Content-Layer zeigt entweder (Free) einen halbtransparenten Schwarzton oder (Pro) das geblurte Vollbild-Screenshot.
Eine `CALayer.mask` mit einem `CGPath` schneidet ein **abgerundetes Rechteck** (Corner-Radius passend zum Fenster) ueber dem aktiven Fenster aus.
Durch das Loch schimmert das aktive Level-0-Fenster **live und scharf** durch.

Warum das beide Probleme loest:

- Abgerundete Ecken: nativ durch den Pfad, kein Halo, keine Kerbe.
- Cutout-Geometrie stimmt: scharfes Fenster, Rest abgedunkelt/geblurt.
- Keine vier Streifen, keine Z-Ordering-Problematik, eine Maske pro Frame-Update.
- Aktiv-Fenster bleibt live (es steht physisch unter dem Overlay und zeigt durchs Loch).

Maske aktualisieren bei Fenster-Bewegung: ein `CGPath(roundedRect:cornerRadius:)`, einmal pro Frame, billig.

Free-Tier braucht gar keinen ScreenCapture (nur Schwarz-Layer + Maske) -> **Null Berechtigungen**, wie design.md fordert.
Pro-Tier setzt den bereits geschriebenen `ScreenCaptureKitBlurProvider` + `MetalBlurRenderer` auf genau dieses Overlay.

### Option 2: Z-Order-Anhebung (verworfen)

Aktives Fenster ueber das Overlay heben.
Scheitert daran, dass man die Window-Ebene **fremder Apps** nicht aendern darf.
Nicht gangbar.

### Option 3: 4-Streifen beibehalten + Corner-Patches

Vier Streifen plus vier kleine Eck-Patches mit radialer Maske.
Komplex, fehleranfaellig, und trotzdem nie so sauber wie eine Pfad-Maske.
**Verworfen** - zu viel Komplexitaet fuer ein schlechteres Ergebnis.

---

## 6. Konkreter Aktionsplan

### Phase 1 - Eine Architektur, Truth rausschmeissen (1-2 Tage)

1. `PerfectOverlay.swift` loeschen.
2. `AppDelegate.activateFocus` umbauen auf `DisplayManager.allOverlays()` + `EffectProvider.attach(...)`.
3. `OverlayWindowController` umschreiben: **ein** Fenster pro Screen, `CALayer.mask` mit rundem Pfad-Loch.
4. `ActiveWindowTracker` um Corner-Radius erweitern (konstant ~10px oder via AX-Abfrage).
5. `windowFrameChanged` aktualisiert die Maske, nicht vier Streifen.

### Phase 2 - Designed Pipeline verkabeln (2-3 Tage)

6. `EffectProvider.updateSettings(...)` an `@AppStorage`-Aenderungen binden (blurRadius/saturation/tint).
7. `ScreenCaptureKitBlurProvider`: `excludingWindows: [overlayWindow]`, Quarter-Res, `MetalBlurRenderer` als einziger Renderpfad.
8. `StateMachine` + `CachingEngine` an `attach`/`detach` koppeln; Mission-Control-Heuristik aktivieren.
9. `activeAppDidChange` als Workspace-Observer registrieren.
10. `ShakeDetector` instanziieren und ans Toggle binden.

### Phase 3 - Feature-Ehrlichkeit (1-2 Tage)

11. `excludedApps`/`perDisplay`/`appGroups` entweder anwenden oder aus der Settings-UI entfernen (keine Placebos).
12. `LicenseManager` ans Studio/Deep-Toggle binden (Free vs. Pro-Pfad).
13. Still-Screenshot-Boot (Decision 7) fuer wahrgenommene Latenz = 0.

### Phase 4 - Quality Gate

14. Build + Lauf-Test auf zwei Aufloesungen.
15. Instruments: 0% GPU im Idle (Designziel), 3-5% aktiv.
16. Eckfall-Checklist aus Task 8.5-8.7 (mixed DPI, Stage Manager, DRM-Fenster).

---

## 7. Entscheidungspunkte fuer Viktor

Vor der Umsetzung muessen drei Dinge feststehen:

1. **Overlay-Geometrie**: Option 1 (Pfad-Maske) - Zustimmung?
2. **Tier-Strategie**: Free = reines Schwarz-Dim + Maske (null Berechtigungen), Pro = Blur via ScreenCaptureKit. Genau wie design.md, oder abweichend?
3. **Scope dieser Session**: Nur Phase 1 (Konzept gerettet, sauberer Cutout + Free-Tier), oder Phase 1-2 (inkl. Blur)?

Mit "ja zu Option 1" kann ich direkt mit dem Rewrite von `OverlayWindowController` und dem Umverkabeln des AppDelegate beginnen.
