# Unchain

<img src="Unchain/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="96" alt="Unchain app icon">

Lean iOS app for controlling smart trainers (Kickr & co.) via the open
**FTMS** Bluetooth standard (Fitness Machine Service) — not a Wahoo-proprietary
protocol, so it works in principle with any FTMS-capable trainer.

[MIT licensed](LICENSE). If Unchain's useful to you, a
[GitHub Sponsors](https://github.com/sponsors/607011) or
[Buy Me a Coffee](https://buymeacoffee.com/607011) contribution toward
keeping it going (mainly an Apple Developer Program membership) is welcome,
always optional — the app itself never asks.

## Status

Unchain has grown through two rough phases – MVP bike-trainer control, then
treadmill/FTMS/workout-file support and beyond – tracked as a running,
dated decision log rather than a snapshot. See
[STATUS.md](STATUS.md) for the full feature history and the
App Store readiness checklist.

## Generating the project

The Xcode project itself isn't kept in the repo; it's generated from
[`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the usual way to avoid `.xcodeproj` merge conflicts).

```bash
brew install xcodegen
cd /Users/olau/Workspace/bahoo-kickass
xcodegen generate
open Unchain.xcodeproj
```

Then, in Xcode, select your own team under *Signing & Capabilities*.

## Known Xcode pitfalls on this Mac (already resolved)

Two issues have already come up here and been fixed — in case they recur after
an Xcode update, here are the fixes:

- **`xcodebuild`/`swift`/Xcode.app crash** with
  `Symbol not found: _XPCTypeBool` (CoreDevice.framework vs. Mercury.framework) →
  fixed with `sudo xcodebuild -runFirstLaunch`. If that doesn't help, additionally
  run `sudo rm -rf /Library/Developer/PrivateFrameworks/CoreDevice.framework` and
  run the command again.
- **"The developer disk image could not be mounted on this device"** when running
  on a real iPhone → usually a stale cache. Fix with:
  ```bash
  mv ~/Library/Developer/DeveloperDiskImages ~/Library/Developer/DeveloperDiskImages.bak
  ```
  Then restart Xcode and reconnect the device — Xcode automatically downloads a
  fresh disk image from Apple.

## Getting workout files (.erg/.mrc)

A ramp test for FTP estimation is bundled with the app (Program tab → "Load
Sample Ramp Test"). For anything else, you need ready-made `.erg`/`.mrc`
files – most
providers require an account for that – one exception:

- **[cyclingintervals.com](https://cyclingintervals.com/)** — free structured
  workouts available directly as `.erg`, `.mrc`, `.zwo`, or `.fit` downloads,
  **no registration/login** required.
- [trainerday.com](https://trainerday.com) (formerly ErgDB) — very large
  library, but downloads usually require login.

## Running

Bluetooth doesn't work in the simulator — the app must run on a real iPhone.

`DEVICE` auto-detects whichever iPhone is currently connected via USB
(`connectionProperties.transportType == 'wired'` in `xcrun devicectl list
devices` – distinguishes a live USB connection from a Wi-Fi-paired-but-not-
connected device, which otherwise looks the same in the device list), so
`make run` picks up Oliver's phone or his wife's without needing
`DEVICE=...` every time it's the other one. Falls back to a fixed default
if nothing's connected by USB right now; override on the command line the
same way as always for a not-currently-plugged-in device, e.g. `make run
DEVICE=Eipättpro`.

`make run`/`make install`/`make debug` only ever push `Unchain.app` (with
`UnchainWatch.app` embedded inside it) to the iPhone – that's *not* the same
as the paired Watch picking up the new embedded build, which normally
depends on the Watch app's own "Automatic App Install" sync and doesn't
reliably (or quickly) reflect a fresh development build. Use
`make install-watch`/`make run-watch`/`make debug-watch` to push straight to
the paired Watch instead, the same way the plain targets do for the iPhone
(`WATCH_DEVICE` defaults to `watchOLA`, override the same way `DEVICE`
works). Bike vs. treadmill behavior on the Watch itself still can't be
tested in the Simulator either – needs a real, paired Watch.

## Idea for later: elevation lookup for GPX tracks without `<ele>`

GPX-route riding (see [STATUS.md](STATUS.md)) is deliberately offline-only for now: a
track missing elevation data is rejected rather than filled in from the
internet. If that turns out to be too limiting in practice:

- Plain OpenStreetMap has *no* elevation data itself (it's a vector map, not
  a DEM), so this needs an actual elevation dataset. The best option found so
  far is **[Copernicus DEM
  GLO-30](https://registry.opendata.aws/copernicus-dem/)** — 30 m
  resolution, near-global coverage, distributed as ready-to-use
  Cloud-Optimized GeoTIFF tiles directly on AWS S3 (AWS's Open Data
  Sponsorship Program: no login, no cost, [freely
  licensed](https://docs.sentinel-hub.com/api/latest/static/files/data/dem/resources/license/License-COPDEM-30.pdf)).
- Rather than a live per-point API call, the nicer fit for this app's
  offline-first design is a **one-time regional tile download**: fetch the
  1°×1° GeoTIFF tile(s) covering a track's bounding box once, cache them
  on-device, and do the elevation lookup locally against the cached raster
  afterwards. Every later GPX import in that region then needs no network at
  all — including out on a ride with no signal — which a live lookup
  wouldn't give you. iOS has no built-in GeoTIFF/COG reader (no
  MapKit/CoreLocation support for this), but a point lookup via the raster's
  own geotransform only needs a small, purpose-built parser, not a general
  raster library.
- Fallback if that turns out to be impractical: a live SRTM-based API like
  [Open-Elevation](https://www.open-elevation.com/) or
  [Open Topo Data](https://www.opentopodata.org/) (both open-source,
  self-hostable) — simpler to integrate, but back to a network call on every
  import, indefinitely, not just the first one per region.
- Either way, this would be the first feature needing network access at all —
  the app has been Bluetooth/HealthKit/local-file-only until now, worth
  flagging explicitly to the user rather than adding quietly.
- Not every trainer supports Indoor Bike Simulation — check via the feature
  overlay (ℹ️ next to the trainer name, look for "Indoor Bike Simulation
  (Grade)" under Adjustable Targets) before relying on it; a graceful
  fallback (e.g. resistance-% approximated from the gradient) isn't
  implemented, since FTMS doesn't guarantee a fixed, predictable relationship
  between resistance level and felt difficulty (see the resistance-mapping
  fix earlier in this project's history) the way it does for grade simulation.

## Idea for later: a true free-form "describe your workout" prompt

The shorthand notation behind **Create** (see [STATUS.md](STATUS.md)) is deliberately a
small, fixed grammar — offline, no account, no ongoing cost. A genuinely
free-form prompt ("give me a hard 45-minute FTP-builder") needs an actual
LLM to turn intent into structure, which is a different, bigger feature:

- Notably, this doesn't need any new code *today* to get real value: `.erg`
  is a simple, documented text format any capable general-purpose LLM can
  already produce directly (this session generated several by hand) — ask
  one for an `.erg` file with the numbers you want, save it, "Load from
  File". TrainerDay's own AI integration works similarly at its core: rather
  than running a proprietary model, they expose their workout/calendar API
  as MCP tools to the user's *own* ChatGPT/Gemini subscription, which does
  the actual reasoning.
- An in-app version of that would need: a network call (the first one purely
  for a *prompt*, distinct from the elevation idea above), an API key (the
  user's own, to avoid ongoing cost/liability on this app's side), and
  critically, the model should return **structured JSON** matching
  `WorkoutProgramBreakpoint`'s shape rather than talking to FTMS or inventing
  free text — reusing the exact same parsing/clamping path a shorthand or
  file-loaded program already goes through, so a hallucinated response can't
  reach the trainer with implausible values unchecked.

## Considered and rejected: an HR+-style heart-rate-locked control mode

TrainerDay has an "HR+" mode: set a target heart rate, and it continuously
adjusts the *power* sent to the trainer to hold you there — a closed-loop
controller, unlike anything else in this app (Power/Resistance/Grade/Program
are all either manual or a fixed, pre-planned schedule; nothing else reacts
live to a sensor's own noisy signal). Deliberately not building this:
heart rate is a poor *control* input, however useful it is as a *monitoring*
one (which is exactly what `HeartRateZone` already covers – live and
post-workout, never driving anything). It's confounded by too much that has
nothing to do with the current training stimulus – riding position, sleep,
heat, caffeine, daily form, cardiac drift even at genuinely constant power
over time – so a controller reacting to it in real time would be reacting to
noise as much as signal, and heart rate's own lag behind a power change
(tens of seconds, more at low fitness) makes naive proportional control
(raise power while HR is below target) prone to overshoot: it keeps pushing
power up while HR is still catching up, then over-corrects down once it
finally arrives. Power and Grade are already exactly the two *direct,
unconfounded* control variables a trainer can hit precisely — there's
nothing an HR-based layer on top would add that either doesn't already
provide more reliably.
