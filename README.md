<img src="Unchain/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="96" align="right" alt="Unchain app icon">

# Unchain

Lean iOS app for controlling smart trainers (Kickr & co.) via the open
**FTMS** Bluetooth standard (Fitness Machine Service) — not a Wahoo-proprietary
protocol, so it works in principle with any FTMS-capable trainer.

## Status (MVP, Phase 1)

- [x] BLE scan for FTMS devices
- [x] Establish connection, request control (`Request Control`)
- [x] Live display: power, cadence, speed
- [x] Manual control via +/− buttons, switchable between **power (5 W steps)**
      and **resistance (1 % steps)**. Press and hold either button to repeat
      continuously (fires once immediately, then keeps stepping after a short
      delay) instead of tapping repeatedly. Resistance percentage maps onto
      the device's own FTMS resistance-level range at its full native 0.1
      resolution (not pre-rounded to whole levels), so steps stay smooth even
      on trainers with a narrow supported range — a small "Device level x.x of
      a–b" caption shows what's actually being sent
- [x] Automatic clamping to the value range reported by the device
- [x] Screen stays awake as long as the app is active in the foreground (no
      background operation, as intended)
- [x] Pairing with a heart rate strap via the open Bluetooth SIG standard
      **Heart Rate Service** (0x180D) — runs in parallel to the trainer
      connection, so it works with virtually any BLE strap (Polar, Garmin,
      Wahoo TICKR, …), not just vendor-specific devices. Reconnects
      automatically if it drops out of range — no button to press, unlike the
      trainer
- [x] Start/Pause/Stop workout controls, sent to the trainer's FTMS control
      point. Automatically detects whether the connected FTMS device is a
      bike or a treadmill (Indoor Bike Data vs. Treadmill Data characteristic).
      After stopping, offers to save the session to Apple Health — as
      **Indoor Cycling** for a bike, or a choice between **Indoor Walk** and
      **Indoor Run** for a treadmill (FTMS itself can't tell those apart) —
      plus a **Cancel** option in case Stop was pressed by accident, which
      resumes the workout exactly where it left off. Elapsed time and distance
      are pause-aware (distance is a rough estimate integrated from live speed)
- [x] Active-energy (calorie) estimate saved alongside each workout: for bike
      workouts, the standard cycling convention of 1 kJ of mechanical work ≈
      1 kcal (integrated from live power, no body data needed); for treadmill
      workouts, the ACSM walk/run metabolic equations from speed and body
      weight (flat ground assumed). No settings screen for sex/height/weight —
      body weight is read directly from the Health app (`NSHealthShareUsageDescription`),
      where it's already the source of truth. Apple's Fitness app then adds
      its own resting-calorie estimate on top to show "Total Calories",
      using whatever profile the user has in their own Health Details
- [x] Live min/average/max shown under each of Watt/RPM/km/h/bpm once a
      workout is running
- [x] After (re)connecting, the currently displayed power/resistance target is
      sent to the trainer right away, so the device and the display can't
      drift out of sync
- [x] Live heart rate zones (5-zone model, % of estimated max HR) shown as a
      small color-coded bar with per-zone durations, both during the workout
      and again in a summary right after saving. There's no HealthKit type for
      "time in zone" to write, and — corrected after checking on a real
      device — the Fitness app's own zone breakdown turns out to be exclusive
      to Apple Watch-recorded workouts, not derived after the fact from
      heart rate samples a third-party app writes. So this is entirely a
      Unchain-side computation, not synced to Health. Max heart rate is the
      crude 220−age formula from the date of birth in Health (read once,
      via `NSHealthShareUsageDescription`) — no settings screen for it

## Status (Phase 2)

- [x] Third **Program** tab next to Power/Resistance: load a `.erg` (power
      target, absolute watts) or `.mrc` file and have the app follow it
      automatically, second by second, via the same
      `setTargetPower`/`setTargetResistancePercent` calls the manual controls
      use — no new FTMS commands needed. Values between breakpoints are
      linearly interpolated, exactly like TrainerRoad/Golden Cheetah/PerfPRO
      interpret the format
- [x] `.mrc` resolves to a **power** target too whenever its header declares
      `FTP = <value>` – real-world exports (e.g. TrainerDay's) mean the
      percentages relative to *that*, not to the connected trainer's own
      resistance-level range, so they're converted to absolute watts at parse
      time (`percent / 100 × FTP`). Only a percent column *without* a
      declared FTP still falls back to the original literal-0–100-%
      resistance-target interpretation, for files that genuinely mean that
- [x] File picked via `.fileImporter` (no dependency on a specific source);
      a bundled sample **ramp test (100→700 W, 1‑minute/+20 W steps)** for FTP
      estimation is one tap away without needing to source a file first
- [x] Profile chart (Swift Charts, first-party, no new dependency) with a live
      progress marker, plus current target / elapsed / total duration
- [x] Mode picker locks while a workout is running/paused, so Program and
      manual control can't fight each other mid-session; the loaded file stays
      available across a Discard/Save so a ramp test can be re-run without
      picking it again — but a plain Power/Resistance session started
      afterwards won't be silently driven by it
- [ ] `.zwo` (Zwift's format) and CSV — not yet; `.zwo` expresses power as
      %FTP, which would need an FTP concept the app doesn't have yet
- [x] The last-used program is remembered across app restarts
      (`WorkoutProgramStore`, `UserDefaults`, plain `Codable` JSON – nothing
      sensitive). A "Recent" button next to "Load from File" opens an overlay
      listing the last 8 used programs (most recent first, each tagged
      **Power**/**Resistance** so the target type is obvious without opening
      the file) — tap one to load it without going back to Files. The list
      only shows programs compatible with the *currently connected* machine —
      today that means the button is disabled entirely while connected to a
      treadmill, since `.erg`/`.mrc` are both cycling-trainer formats
      (`setTargetPower`/`setTargetResistancePercent`); a treadmill would need
      Set Target Speed/Inclination instead, which this app doesn't drive.
      On a genuinely first-ever run, with nothing saved yet, the bundled ramp
      test is loaded automatically so Program mode isn't empty-handed. Manual
      power/resistance targets are restored the same way, via `@AppStorage`
- [x] A Program run's file `DESCRIPTION` is saved to Health as
      `HKMetadataKeyWorkoutBrandName` (repurposed – it's documented for
      studio/instructor names, but it's the metadata key the Fitness app
      actually renders as a subtitle under the workout type; there's no
      generic "notes" field in HealthKit). Only set for runs that actually
      followed the program, never for a manual session that happens to have
      one loaded
- [x] **Load from File" also accepts `.gpx` tracks**, turned into a real FTMS
      grade simulation ride (Control Point op code `0x11`, "Set Indoor Bike
      Simulation Parameters") instead of a fixed power/resistance schedule.
      Offline by design: only the elevation already embedded in the file
      (`<ele>`) is used — a file missing it on even one point is rejected with
      a clear error rather than falling back to an online elevation lookup
      (see the "GPX" idea below, which this grew out of). Distance between
      track points comes from the haversine formula (GPX only has lat/lon);
      elevation is resampled into 50 m windows before deriving grade, to
      avoid GPS/barometric noise turning into a jittery, unrealistic
      resistance signal. Wind speed is always 0 and rolling/wind resistance
      use fixed, reasonable defaults (`FTMS.SimulationDefaults`) — no bike/
      rider model to derive them from. A route is fundamentally
      **distance-keyed**, not time-keyed like `.erg`/`.mrc` — `GradeProfile`
      is its own model with its own `grade(atDistanceMeters:)` lookup,
      unified with `WorkoutProgram` under `WorkoutSession.activeWorkout:
      ActiveWorkout?` (`.program`/`.route`). The "Recent Workouts" list, its
      compatibility filter, and its persistence (`RouteStore`, mirroring
      `WorkoutProgramStore`) all cover routes too, tagged with a **Grade**
      badge to tell them apart from Power/Resistance programs
- [x] Double-tap either workout chart (Program or Route) to cycle through
      zoom levels (full → 10 min/8 km window → 3 min/2 km window), same
      gesture TrainerDay uses — real-world GPX tracks can have dense enough
      points that the full-route view alone is too fine-grained to read.
      The zoomed window is centered on and scrolls with the current playback
      position rather than staying fixed on wherever it was double-tapped
- [x] Universal — runs on iPad too (`TARGETED_DEVICE_FAMILY: "1,2"`), with a
      larger type scale for the metric tiles, their min/avg/max caption, the
      big target/elapsed numbers, and the heart rate zone bar, plus taller
      workout charts (260pt vs. 140pt). Driven by
      `@Environment(\.horizontalSizeClass) == .regular` rather than checking
      the device idiom directly, so a narrow iPad Split View correctly falls
      back to the iPhone-sized layout instead of looking oversized in a
      cramped window. iPad also supports landscape now
      (`UISupportedInterfaceOrientations~ipad`, an idiom-specific override –
      the plain, unsuffixed key still applies to iPhone and keeps it
      portrait-only). The screen content is wrapped in a `ScrollView` as a
      safety net for this: the iPad type/chart scale above was sized against
      generous *portrait* height, and iPad landscape has notably less of it
      to work with, so without this, content could clip on smaller iPads in
      landscape. This isn't a bespoke landscape layout (e.g. a two-column
      arrangement) – just a guarantee that nothing gets cut off
- [x] Tabs and file types are gated on what the connected trainer actually
      reports supporting (`FitnessMachineFeatures.supportsPowerTarget`/
      `supportsResistanceTarget`/`supportsIndoorBikeSimulation`, parsed from
      individual bits rather than string-matching the display names used in
      the feature overlay): no **Resistance** tab without Resistance Target,
      no `.gpx` in the file picker (and no route recents) without Indoor Bike
      Simulation, `.erg`/`.mrc` filtered by extension the same way. New
      **Grade** tab (manual, step-controlled grade %, same pattern as Power/
      Resistance) only appears when Indoor Bike Simulation is supported.
      Power/Resistance default to *supported* while the feature characteristic
      hasn't been read yet, so a slow read never regresses behavior that
      worked before this gating existed; Grade defaults to *unsupported*
      instead, since popping in a moment later beats appearing and then
      vanishing. If the selected tab becomes unavailable (feature read
      completes with a "no"), it falls back automatically rather than leaving
      the picker stuck on a hidden case
- [x] Settings sheet (gear icon in the toolbar, own `SettingsView`) — for now
      the rider's **FTP** (defaults to 188 W) and a **Vibration** toggle
      (off by default), both persisted via `@AppStorage`. Settings are
      app-wide, not tied to a connection, hence their own separate icon/sheet
      rather than living inside the trainer-features overlay. FTP isn't
      consumed by anything yet: `.mrc` files with their own `FTP =` header
      still use *that* value (see the Phase 2 bullet above) — this is a place
      for the app to know the rider's FTP independent of any one file, for
      future use
- [x] With Vibration on, the phone taps briefly (`UIImpactFeedbackGenerator`)
      whenever a running Program workout (`.erg`/`.mrc`) reaches its next
      scheduled file entry — `WorkoutProgram.breakpointIndex(atElapsedSeconds:)`
      tracks *which* entry playback is past, separately from the interpolated
      target value itself, so this fires once per entry rather than
      continuously during a ramp between two differently-valued ones. GPX
      routes don't have this (grade changes continuously with distance, no
      discrete entries to reach)
- [x] Interval Sound: a short procedurally-generated beep
      (`Unchain/Resources/Sounds/IntervalBeep.wav`, `AVAudioPlayer`) plays
      alongside the vibration above, at a configurable **volume** (0–100 %,
      silent at 0 by default) and **type** — **Single Beep** just beeps once
      on arrival; **Countdown** adds one more beep a second for the four
      seconds leading up to it too
      (`WorkoutProgram.nextTransitionTimeSeconds(afterIndex:)`), so a rider
      not looking at the screen gets a heads-up before a step change, not
      just notice of it after the fact. The audio session uses `.playback` +
      `.mixWithOthers` so beeps layer over music/a podcast instead of pausing
      it, and aren't silenced by the mute switch

Deployment target: **iOS 16.0** · Target devices: **iPhone XS** (max. iOS 18 on
this model) and iPad · iPhone portrait-only, iPad portrait + landscape.

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

Bluetooth doesn't work in the simulator — the app must run on a real iPhone
(your iPhone XS is directly suitable for this).

## Idea for later: elevation lookup for GPX tracks without `<ele>`

GPX-route riding (see Status above) is deliberately offline-only for now: a
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
