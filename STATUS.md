# Unchain – Status & Decision Log

Feature history, App Store readiness checklist, and the reasoning behind
notable implementation decisions – moved out of [README.md](README.md) to keep
that focused on what a new contributor or user actually needs first.

## Tested hardware

Not exhaustive – just what's actually been ridden/walked on. Any other
FTMS-compliant trainer or treadmill should work in principle (that's the
point of building against the open standard rather than a vendor-specific
protocol), but hasn't been verified here.

### Bike trainers

- Wahoo Kickr Core

### Treadmills

- Horizon Paragon X (425A)

### HR chest straps

- Polar H10
- Garmin HRM Dual

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
      trainer. Also reconnects on its own to whichever strap was used last
      the moment it's seen again during a scan (a fresh app launch, or the
      device list's pull-to-refresh) — saves the one tap that would
      otherwise be needed every single ride. Remembered by the strap's
      `CBPeripheral.identifier`, which stays stable for a given device on
      this phone; deliberately not extended to the trainer, since connecting
      there also navigates away and requests exclusive control, a bigger
      action than just starting to receive BPM values
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
      where it's already the source of truth. This becomes the workout's
      **Active Calories**; Fitness's "Total Calories" for that same workout
      is Active + whatever **Resting/Basal Energy** (a separate, continuous
      *background* HealthKit metric, `basalEnergyBurned`) happens to be on
      record for that exact time window – not something Unchain reads,
      writes, or has any say over. **Correcting an earlier claim here**: this
      isn't simply "Apple adds an age/weight-based estimate on top" the way
      it was first described – if nothing was actively producing background
      resting-energy samples for that stretch of time (in practice, mostly
      an Apple Watch actually worn then; a lone iPhone's own contribution
      here is inconsistent, undocumented by Apple, and not guaranteed),
      there's nothing for Fitness to add, and Total legitimately just equals
      Active. Deliberately not something Unchain works around by writing its
      own basal-energy figure – that would risk double-counting against
      whatever the system is already tracking in the background
- [x] Live min/average/max shown under each of Watt/RPM/km/h/bpm once a
      workout is running
- [x] After (re)connecting, the currently displayed power/resistance target is
      sent to the trainer right away, so the device and the display can't
      drift out of sync
- [x] Live heart rate zones (5-zone model) shown as a small color-coded bar
      with per-zone durations, both during the workout and again in a
      summary right after saving. There's no HealthKit type for "time in
      zone" to write, and — corrected after checking on a real device — the
      Fitness app's own zone breakdown turns out to be exclusive to Apple
      Watch-recorded workouts, not derived after the fact from heart rate
      samples a third-party app writes. So this is entirely a Unchain-side
      computation, not synced to Health. Zone boundaries are editable, in
      bpm, in Settings (see "Editable Heart Rate Zones" further down) —
      pre-filled from an explicit Max/Resting Heart Rate, also editable
      there, rather than a fixed, unconfigurable Health-derived guess

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
      the file) — tap one to load it without going back to Files, or swipe
      left to delete an entry (`WorkoutProgramStore`/`RouteStore
      .removeRecent(withID:)`) — persisted immediately, while the sheet's
      own list (a local, mutable copy of what was passed in, not something
      it observes live) removes the row itself right away too, so deleting
      doesn't wait on `ControlView` to re-render before it looks deleted.
      The list only shows programs compatible with the *currently connected*
      machine —
      today that means the button is disabled entirely while connected to a
      treadmill, since `.erg`/`.mrc` are both cycling-trainer formats
      (`setTargetPower`/`setTargetResistancePercent`); a treadmill would need
      Set Target Speed/Inclination instead, which this app doesn't drive.
      On a genuinely first-ever run, with nothing saved yet, the bundled ramp
      test is loaded automatically so Program mode isn't empty-handed. Manual
      power/resistance targets are restored the same way, via `@AppStorage`,
      as is the active tab itself (Power/Resistance/Program/Grade) — reopens
      on whichever one was last selected rather than always defaulting back
      to Power. If that tab isn't available on the machine it reconnects to
      (see `availableModes`/`ensureModeIsAvailable()`), it falls back exactly
      like an in-session feature-support change would
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
- [x] Tap an interval on the Program chart (single tap, not the double-tap
      above) to see its duration and target — "3:00 · 150 W" for a flat
      block, "5:00 · 100–150 W" for a ramp — same as tapping an interval in
      TrainerDay's own workout chart. A translucent band highlights the
      selected interval's time span on the chart itself; tapping it again
      (or tapping outside any interval) clears the selection. Values shown
      already reflect the live intensity adjustment, matching what the
      Target curve itself is currently drawing — this doesn't have its own
      separate notion of "the plan". Single- and double-tap live on the
      same `.chartOverlay` gesture, `.exclusively(before:)`-chained with the
      double-tap listed first — that's what makes SwiftUI hold off firing
      the single-tap handler until it's sure a second tap isn't coming,
      rather than the first tap of a double-tap also firing it. The
      selection also clears itself automatically 5 s after being made
      (`.task(id: selectedBreakpointIndex)` — cancels and restarts on every
      change, so re-tapping always resets the clock instead of an earlier
      selection's timer wiping out a newer one) and the moment the workout
      (re)starts (`.onChange(of: workoutState)`), so a stale selection
      never lingers into the ride itself
- [x] Same tap-to-inspect on the Route chart – tap a smoothed window to see
      its span and grade, e.g. "50 m · 8.2 %" (`GradeProfile
      .breakpointIndex(atDistanceMeters:)`, the distance-keyed counterpart
      to the Program chart's time-keyed one, both mirroring the same
      boundary rule: landing exactly on a window edge already reads as the
      new window). A window's grade is flat by construction
      (`GradeProfileBuilder` holds it constant across each smoothing
      window), so this only ever shows a single value in practice, not a
      range – the label still falls back to one if it ever didn't, same
      as the Program chart's ramp case
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
      the picker stuck on a hidden case. Tab order: **Power, Grade, Program,
      Resistance** (each still only shown when supported) — deliberately not
      declaration order in `ControlMode`, so `availableModes` builds the list
      itself rather than via `.allCases`
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
- [x] A running workout now survives being backgrounded (switching to another
      app, screen lock) instead of silently freezing — see
      `UIBackgroundModes` (`bluetooth-central`, `audio`) in `project.yml`.
      `WorkoutSession` derives elapsed time from `Date()` rather than
      counting `Timer` ticks, so a gap (the app suspended, no ticks fired at
      all) reads correctly the moment the next update arrives instead of
      silently losing that time; distance/work/heart-rate-zone time are
      integrated over the *actual* real time since the last update for the
      same reason, rather than assuming exactly one second between them.
      Progress itself is driven by two paths: the normal once-a-second
      `Timer` while the app is on screen, plus a subscription to the
      trainer's live BLE metrics, which keeps arriving in the background with
      `bluetooth-central` declared — so a Program/Route target still gets
      re-sent to the trainer, not just the on-screen numbers frozen at
      whatever they were when the app was left. On returning to the
      foreground, `ControlView` forces one immediate refresh (via
      `scenePhase`) so the UI shows caught-up numbers right away rather than
      stale ones for up to a second. Not covered: the OS fully terminating
      the process (e.g. under memory pressure) rather than just suspending
      it — surviving that would need CoreBluetooth state restoration
      (`CBCentralManagerOptionRestoreIdentifierKey`), which isn't
      implemented
- [x] **Create** button next to Load from File/Recent: types a workout
      directly in the app via a compact shorthand notation
      (`ShorthandWorkoutParser`) instead of needing an actual `.erg`/`.mrc`
      file – e.g. `10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min
      55%FTP`, with `%FTP` resolved against the FTP set in Settings, `->` for
      a ramp within one step (`20min 100W->300W`), and arbitrarily nested
      `Nx(...)` repeat groups. Parses live with an inline preview chart and a
      specific error message (missing FTP, a malformed step, …) rather than
      a generic failure. Entirely offline – no network call, unlike a true
      free-form AI-generated workout would need (see "Idea for later" in
      [README.md](README.md))
      – deliberately power-only, since there's no %-of-resistance-range
      equivalent that would mean anything portable. Saving runs through the
      exact same `loadProgramIntoSession(_:)` every other load path already
      uses, so it lands in "Recent" like any other program, no separate
      storage needed
- [x] **Export…** next to a loaded Program: the reverse of loading one –
      `WorkoutProgram.fileContents()` serializes back to the `.erg`/`.mrc`
      text format (`.erg`/`WATTS` for a power target, `.mrc`/`PERCENT` for
      resistance, matching whichever the program already is), offered via
      `.fileExporter` so the user picks the destination themselves (iCloud
      Drive, On My iPhone, any other provider) — the same native picker
      `.fileImporter` already uses for loading, just the write side. Not
      Unchain-specific storage: the result is a plain, portable file other
      apps can read too, and re-importing it resolves to the exact same
      program (round-trip tested). Works for *any* currently loaded Program,
      not just ones created via Create — a file loaded from Files, tweaked
      by re-typing, could be re-exported the same way. Routes (GPX) aren't
      covered, no serializer for those
- [x] Feedback from an actual 45-minute ride, in one pass:
  - **FTP reference line** on a power-kind Program chart — a dashed
    `RuleMark` at the FTP set in Settings, labeled, so the target profile can
    be read against it at a glance without doing the math
  - **Actual power curve** plotted alongside the planned one, from a new
    `WorkoutSession.powerHistory` (one sample a second, deduplicated
    regardless of how often a refresh actually fires — see the backgrounding
    entry above). Power-kind Programs only – a resistance-kind program's
    y-axis is 0–100 % of the trainer's own range, not watts, so an actual-W
    line there would be a different unit on the same axis. Target, Actual,
    and FTP all tag their marks with `.foregroundStyle(by:)`, so all three
    show up in an automatic legend (`.chartForegroundStyleScale`) rather than
    FTP being just an unlabeled dashed line
  - **Y-axis scale**: three attempts to get this right. Leaving it to Swift
    Charts' automatic domain fit meant a single real power spike dragged the
    *whole* axis with it (200 W → 600 W from one moment above target);
    clamping the domain to just the plan fixed that but revealed a second
    issue – Swift Charts' automatic tick *labels* don't necessarily reach the
    domain's own upper bound, so FTP could end up drawn above the highest
    labeled gridline; forcing explicit, evenly-spaced ticks
    (`AxisMarks(values: .stride(by:))`) fixed *that* but could overlap once
    the chart was too short to fit as many ticks as the step demanded.
    Landed on: leave tick placement to Swift Charts after all (it has the
    actual rendered height to work with, this code doesn't), but let
    **`chartHeight` itself grow** with the ceiling instead of stretching a
    fixed-size box – deliberately, so genuinely exceeding the plan shows up
    as a taller chart (rewarding), not the same-size chart with the target
    line now looking smaller (deflating). The ceiling is still the smallest
    multiple of a fixed step (50 W for power, 25 % for resistance) at or
    above the largest of the plan's own max, FTP, and the highest *actual*
    reading so far (`session.powerStats.maxValue`), and height is a fixed
    points-per-watt multiple of that ceiling – chosen so a plan-only ceiling
    (no overshoot yet) lands close to the chart's original fixed height.
    Resistance-kind programs keep that original fixed height outright – no
    FTP/actual-power concept there for the ceiling to ever exceed the plan
  - **Min/avg/max tap-to-toggle**: showing it as a permanent line under the
    live reading meant the metric tiles (Watt/RPM/km/h/bpm) grew taller the
    moment a workout started collecting samples, shifting everything below –
    and the text had to stay tiny (10 pt) to fit alongside the live value.
    Now a tap toggles the *same* line between the live reading and a
    "↓min Øavg ↑max" summary, both sharing one `lineLimit(1)` +
    `minimumScaleFactor` text at the same font ceiling as the live value –
    same height either way (nothing shifts, ever), and the summary renders as
    large as the tile's width actually allows instead of a fixed tiny size
- [x] Live **intensity adjustment** for a running Program, +/- in 1 %
      steps (same `RepeatingStepButton` the manual Power/Resistance tabs
      already use), flanking the big target number. Deliberately *not* the
      same thing as changing FTP in Settings — FTP only ever resolves
      `%FTP` at *load* time (a `.mrc`'s own header, or the shorthand
      notation), so a live Settings change can't retroactively rescale an
      already-loaded program's baked-in watt values; this instead applies a
      session-local `WorkoutSession.intensityAdjustmentPercent`
      (floored at -50 %, no ceiling — the trainer connection itself already
      clamps whatever this produces to its own reported range before
      sending anything, so this doesn't need to be the safety net too; not
      persisted, reset to 0 whenever a program/route is
      (re)loaded) live to every resolved target, both what's actually sent
      to the trainer and everything displaying it — the live number, and
      the chart's Target curve/y-axis ceiling (`WorkoutSession
      .adjustedValue(_:byPercent:)`, one `static` formula shared by both, so
      they can never drift apart). Kind-agnostic – scales a resistance-kind
      program's percent target exactly the same way. The percentage (e.g.
      "+5 %", or "±0 %" when neutral) sits in a fixed-width slot *between*
      the two buttons rather than a separate line below — always shown, not
      just once adjusted, and at a constant width regardless of digit count
      or sign, so the buttons themselves never shift position either way
- [x] Fixed: `RepeatingStepButton` (the +/- press-and-hold control used
      everywhere – Power/Resistance/Grade, and now Intensity) could
      sometimes keep auto-repeating on its own, with no way to stop it
      short of leaving the screen. Root cause: plain `DragGesture` has no
      `.onCancel` – if the system ever cancels the gesture rather than
      ending it normally (a re-render mid-press, e.g. from the once-a-second
      workout updates this sits right next to, is the likely trigger)
      `.onEnded` simply never fires, leaving the repeat `Timer` running on
      the run loop, fully orphaned from the view, and `isPressing` stuck
      `true` so a fresh press can't even start a new (correctly-behaving)
      one. Three layers: `.simultaneousGesture` instead of `.gesture`, so a
      nearby gesture (the screen's own `ScrollView`, the chart's
      double-tap-to-zoom) can't claim the touch exclusively and cancel this
      one; `.onDisappear` stops the repeat if the view is ever genuinely
      removed mid-press; and a hard 20 s cap on one continuous repeat
      regardless of anything else, so even if both of those somehow fail
      too, it self-terminates rather than running indefinitely
- [x] **Localization: German**, alongside the English source language. Uses
      Xcode 15+ String Catalogs (`Unchain/Resources/Localizable.xcstrings` for
      UI text, `InfoPlist.xcstrings` for the three `NSUsageDescription`
      Bluetooth/Health strings) rather than old-style `.strings` files – no
      new dependency, and it's what `xcodegen`/Xcode now generate by default.
      Every user-facing string literal (`Text`, `Button`, `Label`, `Toggle`,
      `Picker`, alert titles/messages, error descriptions, axis/unit labels,
      …) either auto-localizes via `LocalizedStringKey` (plain string
      literals passed directly to a SwiftUI view) or is wrapped in
      `String(localized:)` for anything computed/interpolated first. Two
      related bug classes turned up and got fixed while auditing for this:
      a `String` *variable* built from a literal and then handed to `Text` or
      a chart axis-label modifier does **not** auto-localize (only a literal
      at the call site does) – found and fixed in `MetricTile`'s title,
      `DeviceListView`'s status text, both workout charts' zoom-window
      labels, and `IntervalSoundType`'s display name; and `ControlMode`'s
      `rawValue` is both the on-screen tab label *and* the
      `@AppStorage("lastActiveMode")` persistence key, so it stays English/
      unlocalized on purpose and gained a separate, translated `displayName`
      instead – translating `rawValue` itself would silently reset (or worse,
      keep an unrelated) remembered tab after a locale change. `String(format:
      locale: .current, …)` was added to every locale-sensitive numeric
      formatter (so e.g. a German device shows "1,5" not "1.5"), *except* the
      handful of mm:ss time formatters (no decimal point to localize) and the
      `.erg`/`.mrc` file serializer, which deliberately keeps
      `Locale(identifier: "en_US_POSIX")` – it's a machine-readable file
      format read back in by this app and others regardless of what locale
      wrote it, so it must never follow the device locale. The FTMS spec's
      own field names (shown verbatim in the diagnostic "Trainer features"
      overlay, see `FitnessMachineFeatures`) are deliberately left
      untranslated – translating them would make that overlay less useful for
      cross-referencing against the spec or another app, not more. Verified
      by inspecting the actual built `.app` bundle: `de.lproj/
      Localizable.strings` and `de.lproj/InfoPlist.strings` both compile in
      with all entries present, correct positional format specifiers for
      multi-argument strings (e.g. `"Device level %@ of %@"` →
      `"Gerätestufe %1$@ von %2$@"`), and no `en.lproj` needed (English is the
      source language, baked in directly). Spanish/French were discussed and
      deliberately deferred – German only for now
- [x] **Explicit language override**, in Settings, on top of the above –
      defaults to **System** (the device's own Language & Region setting,
      unchanged from before), but "English"/"Deutsch" can be picked
      explicitly and take effect immediately, no app restart needed. iOS has
      no supported API to switch `Text`/`String(localized:)`'s resolved
      locale at runtime; `LanguageManager` uses the standard workaround –
      swizzling `Bundle.main`'s class so its `localizedString(forKey:value:
      table:)` (what both ultimately resolve through, String Catalogs
      included) reads from a specific `.lproj` bundle instead of letting the
      OS pick one. Picking "System" again just clears the override, falling
      back to the OS's own resolution. `UnchainApp` re-applies the stored
      override at launch and forces a full content-view rebuild
      (`.id(languageOverride)`) whenever it changes, so every already-
      rendered label picks up the new language immediately rather than
      waiting for unrelated state to trigger its own next redraw – the one
      trade-off being that changing the language while the Settings sheet is
      open closes that sheet along with the rest of the tree it's part of.
      Known limitation: this overrides string *lookup* only, not
      `Locale.current` itself, so the app's own locale-aware
      `String(format:)` calls (e.g. FTP-derived decimal values) still follow
      the true device locale, not this override. The two language names in
      the picker ("English"/"Deutsch") are deliberately *not* translated –
      shown in their own language regardless of which is currently active,
      the same convention every OS/app language picker uses
- [x] **Explicit Max/Resting Heart Rate settings**, right below FTP in
      Settings — same "0 shows as an empty field" `TextField` treatment as
      FTP. Replaces the old fixed, unconfigurable Health-derived guess: Max
      is pre-filled *once*, the first time it's shown empty, with an
      age-based estimate from the date of birth in Health — **Tanaka's
      formula** (208 − 0.7 × age), a more accurate, more recent revision of
      the cruder, ubiquitous 220−age rule of thumb; Resting from the most
      recent resting-heart-rate sample Health has on record (written by the
      Watch on its own) – or a flat **60 bpm** if Health has none at all,
      rather than leaving the Karvonen calculation below without a resting
      heart rate entirely (see the next bullet). Both are freely
      overwritable, e.g. with a value from an actual lab or max-effort test.
      `WorkoutSession` (which
      classifies live BPM samples into heart rate zones, see `HeartRateZone`)
      reads both directly via `UserDefaults` at the point of use, the same
      pattern already used there for Vibration/Interval Sound, rather than a
      value pushed in once per Bluetooth heart rate strap connection — so an
      in-Settings edit takes effect immediately, even mid-ride
- [x] **Editable Heart Rate Zones** — the 5-zone model's four boundaries
      (Zone 1→2, 2→3, 3→4, 4→5) are now plain, editable bpm values in
      Settings rather than a hardcoded formula. Prompted by real-ride
      feedback: an Apple Watch-recorded outdoor ride's own zone breakdown in
      Fitness (which Unchain can't read back — no public API exposes it) had
      boundaries that didn't line up with what the app would have shown for
      the same ride, because Apple's own zones are personalized using Cardio
      Fitness (VO2 max), a calculation that isn't published as an exact
      formula and so can't be reproduced. Letting the rider type in the same
      numbers Fitness already shows them is the practical fix. Each boundary
      still defaults, until explicitly set, to a formula — now **Heart Rate
      Reserve (the Karvonen method)**: `resting + fraction × (max −
      resting)` for fraction 60/70/80/90 %, applied to the *reserve* actually
      available during exercise rather than max heart rate outright (closer
      to what Apple's own zones reportedly use too), falling back further to
      the plain %-of-max-heart-rate breakpoint whenever no resting heart
      rate is on record. `HealthKitManager.fetchHeartRateProfile` now reads
      both Max and Resting Heart Rate from Health in one combined call
      (`NSHealthShareUsageDescription` updated to mention resting heart rate
      too)
- [x] Settings screen redesign to fit the growing list of sections: every
      section's explanation moved from a permanent footer into a small ℹ️
      `InfoButton` next to its header, revealed in a compact popover on tap
      (`.presentationCompactAdaptation(.popover)` from iOS 16.4 on; a plain
      sheet-style adaptation below that, since the deployment target is
      16.0) — keeps the screen a reasonable height with FTP, Heart Rate,
      Heart Rate Zones, Vibration, Interval Sound, and Language all on one
      page
- [x] The Settings gear now also appears on the device list (start) screen,
      not just inside an active trainer session — rider profile data (FTP,
      Max/Resting Heart Rate, zone boundaries) is worth setting up before
      ever pairing anything, not just mid-ride
- [x] Fixed: saving a completed workout to Health could silently fail –
      reported after a real ride where every write permission had been
      granted, but the (newly added, for Heart Rate Reserve zones) Resting
      Heart Rate *read* permission hadn't been responded to yet. Root cause:
      `HealthKitManager.save()` and `fetchHeartRateProfile()` (the Settings
      prefill) shared one combined read-type set, so `save()`'s own
      `requestAuthorization` call ended up waiting on a Settings-only
      permission it doesn't even use, mid-save – which apparently failed
      silently rather than surfacing a retry-able prompt. Fixed by splitting
      into two disjoint, minimal read-type sets, each requested only by the
      one function that actually uses it (`bodyMassReadType` for `save()`,
      `heartRateProfileReadTypes` for `fetchHeartRateProfile()`) – whatever
      is or isn't granted in Settings can now never again affect whether a
      workout saves
- [x] **"Log a Workout…"**, right at the bottom of Settings (see
      `LogWorkoutView`) – backfills a workout into Health that Unchain never
      recorded live, e.g. one done without the app running, or one whose
      live save failed outright (see the bug fixed just above). Type
      (Indoor Cycling/Walk/Run), start time, duration, and optionally
      distance and (cycling only) average power – the last of which is what
      turns into a calorie estimate via the exact same `EnergyEstimator`
      formulas a live save uses (`workDoneKilojoules = avgWatts × duration`
      for cycling; distance + duration + body weight from Health for walk/
      run). Reuses `HealthKitManager.save(_:as:)` and `WorkoutSummary`
      completely unchanged from the live save path in `ControlView` – same
      validation, same "no accurate figure means no invented one" rule,
      same error handling – just with `heartRateSamples`/
      `heartRateZoneSeconds` always empty, since there's nothing to log
      after the fact for either
- [x] **A minimal Apple Watch companion** (`UnchainWatch` target, embedded
      in `Unchain.app/Watch` – see `project.yml`), prompted by a real ride
      where Fitness's "Total Calories" for the workout turned out identical
      to "Active Calories": that's not a bug, it's what happens when nothing
      was actively producing background Resting/Basal Energy samples for
      that time window – in practice, mostly a Watch actually *running its
      own workout session*, not just worn (see `HealthKitManager`'s doc
      comment for the full explanation, corrected there after an earlier,
      too-simple claim). Deliberately minimal, matching that one goal
      exactly: a single Start/Stop screen (`WatchWorkoutManager`,
      `ContentView`), no live power/heart-rate display. Tapping Start there
      starts a real `HKWorkoutSession`/`HKLiveWorkoutBuilder` on the Watch
      *and*, via `WatchConnectivity`, tells Unchain on the iPhone to start
      its own trainer-driving session at the same moment – tapping Stop
      (on either device) ends both. The Watch's own session becomes the
      workout saved to Health (more accurately than Unchain's own estimate
      can be, with a proper Total this time); Unchain's phone-side save is
      skipped for that one, rather than writing a duplicate – see
      `ControlView`'s `isWatchCompanionWorkout`/`configureWatchCompanion()`
      and `WatchConnectivityManager`. Originally Indoor Cycling only – the
      Watch has to declare its workout's activity type *before* the ride
      starts, and unlike a bike, FTMS can't tell a treadmill workout's
      eventual Walk/Run choice apart that early, which used to only get
      asked *after* stopping (see the "Save workout to Apple Health?"
      dialog's `saveDialogButtons`). Superseded by the next entry, which
      moves that choice earlier and lifts the restriction
- [x] Fixed (build tooling): embedding `UnchainWatch` made `make build`
      (and CI) fail outright – a blanket `-sdk iphoneos`/`-sdk
      iphonesimulator` gets applied to *every* target in the build, forcing
      the embedded watch target to also try building against the iOS SDK
      instead of its own watchOS one. `Makefile`/`ci.yml` both now omit
      `-sdk` entirely, letting each target resolve its own platform from
      its own `project.yml` settings instead – verified this still defaults
      the main `Unchain` target to exactly the same `Debug-iphoneos` output
      as before, so nothing else needed to change. Separately: a watchOS
      app's icon asset-catalog step needs a watchOS Simulator runtime
      installed *even for a device build* – on a Mac that's missing one,
      `make build`/`make archive` fail with "No available simulator
      runtimes for platform watchsimulator" until `xcodebuild
      -downloadPlatform watchOS` (or Xcode → Settings → Platforms) adds it
- [x] Fixed: the Watch's own **Stop** button could do nothing at all –
      confirmed on a real device. Two separate causes: `ContentView`'s
      `.running` case put the Stop button below the visible area on smaller
      watch models (fixed by wrapping the whole screen in a `ScrollView`),
      and `stop()` called `session?.end()` immediately after
      `stopActivity(with:)` with no wait for that to actually take effect
      first, which could silently drop the `.ended` transition and leave the
      UI stuck on "Stopping…" forever. Restructured to be state-driven
      instead: `end()` is now only called from `HKWorkoutSessionDelegate`
      once `.stopped` is actually confirmed (see `WatchWorkoutManager
      .stop()`/`workoutSession(_:didChangeTo:...)`), with an 8-second
      watchdog (`armStoppingWatchdog()`) as a hard backstop if that
      confirmation never arrives at all
- [x] Fixed: repeated reinstalls during testing could leave an
      `HKWorkoutSession` orphaned at the system level – still running, with
      no `WatchWorkoutManager` left to manage it – which then saved to
      Health separately from whatever session came after it, showing up as
      duplicate entries for what felt like one continuous ride.
      `WatchWorkoutManager.init()` now calls `HKHealthStore
      .recoverActiveWorkoutSession(completion:)` on launch and cleanly ends
      any such orphan through the same state-driven stop path above, rather
      than silently resuming it as a fresh "Recording" state
- [x] The **Disconnect** toolbar button in `ControlView` is now disabled
      while a workout is running or paused – it used to end the Bluetooth
      connection, and with it the workout's progress, with no confirmation
      at all, one accidental tap away
- [x] The Program workout chart now overlays live **heart rate** as a
      second trace whenever a strap has produced at least one reading this
      workout (`WorkoutSession.heartRateHistory`), on its own right-hand
      axis. Swift Charts has no native second y-domain, so
      `WorkoutProgramChart` fakes one: the trace is plotted by linearly
      rescaling bpm into the chart's existing Watt/Percent range
      (`rescaledHeartRateValue(_:)`), while the right-hand axis' tick
      *labels* show the original bpm figures back
      (`unrescaledHeartRateValue(_:)`) at a handful of fixed, evenly-spaced
      values. That bpm range (`heartRateDomain`) is fixed at 40–220 rather
      than fitted to the ride, so the axis doesn't rescale itself every time
      a new min/max reading comes in. The Watt/Percent axis itself stays on
      the left, same as always – now explicit (`AxisMarks(position:
      .leading)`) rather than implicit, but still with automatic tick
      placement (see the note further up on why an explicit `.stride(by:)`
      step isn't safe there), to make room for the new axis on the right
- [x] New **Speed Display** Settings picker (`SpeedDisplayUnit`: km/h /
      min/km / Off) controls the third live-metric tile in `ControlView` –
      km/h is a fairly meaningless number on an indoor trainer, and running/
      walking is conventionally tracked as pace (min/km,
      `paceString(fromSpeedKmh:)`) instead. Choosing **Off** frees that tile
      for a live **kcal** reading instead, cycling only
      (`WorkoutSession.liveActiveEnergyKcal`, the same running total the
      eventual Health save's Active Calories comes from) – a treadmill
      workout's Walk/Run split isn't knowable until after Stop (see
      `saveDialogButtons`), so live kcal isn't available there and the tile
      falls back to km/h regardless of the setting
- [x] Fixed two issues in the new heart rate overlay above, both reported
      from a real device: the Watt/Percent axis label could jump to the
      right, overlapping the heart rate axis' own tick labels there, and the
      heart rate axis itself didn't appear until a workout had actually
      started, even with a strap already connected. First cause:
      `.chartYAxisLabel(unitLabel)`'s default `.automatic` position stopped
      reliably resolving to the left once a second, right-hand axis
      existed – pinned explicitly to `.leading` instead. Second cause:
      `showsHeartRate` only looked at `heartRateHistory`, which stays empty
      until a workout is actually running and collecting samples –
      `WorkoutProgramChart` now also takes `isHeartRateConnected`
      (`bluetooth.currentHeartRateConnection != nil`) so the axis shows up
      the moment a strap is paired, with an empty trace until there's
      actually something to plot
- [x] Fixed: a heart rate strap already known to the app (paired at least
      once before, see `lastHeartRateStrapUUIDKey`) could fail to
      auto-reconnect. Root cause: the only auto-reconnect path was
      discovery-based (`centralManager(_:didDiscover:)`, matching a
      just-scanned device against the stored UUID) – but `ControlView`
      itself never scans, and `connect(to:)` stops the device-list scan the
      moment a trainer is picked. A strap that hadn't already reconnected by
      then – switched on afterwards, or just missed during the brief
      device-list scan – could never be found again for the rest of the
      session. Fixed by adding a second, scan-independent path
      (`attemptAutoReconnectHeartRateStrap()`, run once Bluetooth is ready):
      `central.retrievePeripherals(withIdentifiers:)` recovers the
      peripheral purely from its stored identifier, and issuing
      `connect(_:options:)` on it right away leaves the request pending with
      CoreBluetooth, which completes it automatically the moment the strap
      is actually reachable – no scanning required, and no need to already
      know it's currently in range
- [x] The kcal tile (see above) now swaps places with bpm, but only when
      it's actually showing kcal – km/h/pace still sit ahead of bpm as
      before. Requested since kcal ending up right next to Watt/RPM, ahead
      of heart rate, read oddly given how closely related the two already
      are everywhere else in the app (e.g. the post-workout summary)
- [x] The tap-to-toggle min/average/max summary under each metric tile
      (`MetricTile`) now stacks its three values vertically, one per line,
      at the same font size as the tile's plain reading – legible at a
      glance mid-ride, same as that reading is, rather than all three
      squeezed onto one line and auto-shrunk to fit, which read small
      enough to need a second look. Trade-off: the tile now does grow
      taller while a summary is showing, unlike before this was requested,
      when tap-to-toggle deliberately kept every tile's height constant
- [x] The Watch companion now works for a treadmill too, not just a bike –
      prompted by a good catch: the Watch's idle screen showed a fixed
      bicycle icon, which stopped making sense the moment Start there could
      also mean Walk or Run. The actual blocker had been deciding *which*:
      the Watch has to declare its `HKWorkoutConfiguration.activityType`
      before the workout starts, but FTMS can't tell a treadmill's eventual
      Walk/Run apart that early – previously only asked, on the phone,
      *after* stopping. Fixed by moving that choice earlier instead: tapping
      Start for a treadmill – on the phone screen *or* the Watch – now shows
      a "Walking or running?" dialog on the phone first (`ControlView`'s
      `startWorkout()`/`chooseTreadmillActivity(_:)`), and only then starts
      either side; the old post-stop Walk/Run choice is gone; the save
      dialog now shows one button either way, same as a bike always did.
      For a Watch-triggered start, `WatchConnectivityManager.onStartRequested`
      changed from a synchronous `Bool` return to a completion callback,
      since the phone's reply now has to wait on the rider actually
      answering that dialog rather than being knowable right away; it
      carries the chosen `HKWorkoutActivityType` back to
      `WatchWorkoutManager.beginSession(activityType:)`, which no longer
      hardcodes `.cycling`. Also added `distanceCycling`/
      `distanceWalkingRunning` to the Watch's own HealthKit share types – a
      treadmill workout can get distance readings straight from the Watch's
      motion sensors even indoors, unlike a bike, so leaving either out
      would risk the exact same silent per-type write failure
      `HealthKitManager`'s doc comment describes on the phone side. The
      Watch's idle icon is now a generic flame instead of the bicycle. Live
      kcal (see above) stays cycling-only for now – the walk/run formula
      still needs a live distance/body-weight estimate wired up, unlike the
      simpler mechanical-work-based cycling one – even though Walk vs. Run
      itself is technically known early enough now
- [x] **Crash/hang diagnostics via MetricKit** (`DiagnosticsReporter`,
      `DiagnosticsView`, reachable from Settings), prompted by a real
      question: does crash reporting even work without TestFlight or the
      App Store? It does, two ways already, with no code at all – iOS keeps
      its own on-device crash logs (Settings → Privacy & Security → Analytics
      & Improvements → Analytics Data) regardless of how an app was
      installed, and Xcode's Devices window (Window → Devices and Simulators
      → [device] → View Device Logs) pulls and symbolicates those directly
      from a connected iPhone. `DiagnosticsReporter` adds a third, in-app
      option: `MXMetricManagerSubscriber`'s `didReceive(_:[MXDiagnosticPayload])`
      hands the app a JSON diagnostic report – crash, hang, CPU/disk-write
      exception – the next time it launches after one happens (per Apple's
      own MetricKit docs, this can lag up to a day, and won't arrive at all
      until the app is reopened), saved as-is to a file in the app's own
      sandboxed storage. No parsing/symbolication attempted here – that's
      still easiest done by opening the exported file in Xcode or a text
      editor. `DiagnosticsView` just lists saved reports (newest first,
      dated from the filename's own embedded timestamp rather than the
      file's actual creation/modification date – deliberately, since the
      latter would pull in the "File Timestamp APIs" required-reason
      category `PrivacyInfo.xcprivacy` would then need a reason for) with a
      `ShareLink` per row to export one (AirDrop/Mail/Files/…) and a
      swipe-to-delete/"Delete All" for cleanup. Everything stays local until
      you explicitly share a file yourself – documented as such in a new
      "Crash & hang diagnostics" section in `docs/privacy.html`, which also
      had to stop claiming "no analytics or crash-reporting SDKs" quite so
      simply
- [x] Fixed a real crash, caught via the Diagnostics feature above (an
      "unrecognized selector" abort, thrown from deep inside Foundation's
      `__NSThreadPerformPerform` – no Unchain frames on the stack at all,
      since that mechanism delivers a delegate callback on a deferred basis,
      well after whatever originally scheduled it has returned). Root cause,
      confirmed by the rider having navigated back mid-workout: leaving
      `ControlView` had never actually torn down the BLE connection –
      `BluetoothManager.clearConnection()` only dropped the app's own
      reference to `TrainerConnection`, not `cancelPeripheralConnection`, so
      CoreBluetooth kept delivering callbacks to an "orphaned"
      `TrainerConnection` no longer referenced by the UI. If it later
      deallocated while a callback for it was still queued for deferred
      main-thread delivery, that callback could land on already-freed/reused
      memory once it finally arrived – textbook cause of exactly this crash
      shape. Two fixes: `clearConnection()` now calls `disconnect()` first
      (making `disconnectCurrent()` redundant – removed); and, since only
      the in-app "Disconnect" button was ever guarded against a running
      workout, not iOS's own edge-swipe-back gesture, a small
      `UIViewControllerRepresentable` (`InteractivePopGestureDisabler`)
      now reaches past SwiftUI to disable
      `UINavigationController.interactivePopGestureRecognizer` for the
      duration – `.navigationBarBackButtonHidden(true)` alone only hides the
      *button*, not the gesture, a genuine SwiftUI API gap
- [x] Fixed: connecting to the first-ever treadmill actually tested against
      this app (a Paragon X) got stuck on "Reading device data …" forever –
      feature discovery worked fine, but control was never granted. Root
      cause: `TrainerConnection.didDiscoverCharacteristicsFor` called
      `requestControl()` immediately after `setNotifyValue(true, for:)` for
      the control point, with no wait for CoreBluetooth to actually confirm
      that indication subscription took effect on the peripheral first – a
      race against the trainer's own response. If the trainer processed the
      Request Control write and sent its response indication before the
      phone had genuinely finished subscribing, that indication got silently
      dropped, and `handleControlPointResponse` (the only path to `.ready`)
      never fired, with no error surfaced either. Fixed by moving
      `requestControl()` into the new
      `peripheral(_:didUpdateNotificationStateFor:error:)` delegate method,
      gated on the control point's own `characteristic.isNotifying`
      actually turning `true` first – the earliest point it's genuinely
      safe to ask. This was always a latent bug, for any FTMS trainer –
      the bike used for testing so far apparently just never lost that race
- [x] `TrainerMetrics(treadmillData:)` now also parses Instantaneous Power,
      not just Speed – noticed once the Paragon X's own feature list (see
      `TrainerFeaturesView`) showed it as supported. Getting there means
      correctly skipping every optional field the FTMS spec places between
      Speed and Power in the exact order/byte-width it defines (Average
      Speed, Total Distance, Inclination + Ramp Angle Setting, Elevation
      Gain, Instantaneous/Average Pace, Expended Energy, Heart Rate,
      Metabolic Equivalent, Elapsed/Remaining Time, Force on Belt) – get any
      one width wrong and Power reads from the wrong offset entirely,
      silently, not as an obvious failure. Verified against the Bluetooth
      GATT Specification Supplement's own
      `org.bluetooth.characteristic.treadmill_data` field table rather than
      going from memory. `instantaneousCadenceRPM` deliberately still never
      gets set for a treadmill – FTMS defines no cadence field there at all,
      unlike Indoor Bike Data (nothing rotating to count) – and the RPM tile
      in `ControlView.metricsRow` no longer even shows for a treadmill,
      since it could never have shown anything there anyway. Confirmed:
      populating `workDoneKilojoules` now for a power-reporting treadmill
      doesn't affect the Health save's calorie estimate at all –
      `HealthKitManager.estimateActiveEnergyKcal` branches on the actual
      `activityType` being saved as, not on whether that figure happens to
      be present, so a treadmill save still always goes through the ACSM
      walk/run formula regardless
- [x] Likely fixed: the RPM tile fix above (should be gone on a treadmill)
      turned out to still show up on a Paragon X 425A – along with the
      "Off" Speed Display setting's kcal tile, itself also supposed to be
      bike-only. Both gated purely on `TrainerConnection.machineKind`, so
      both pointed at the same thing: `machineKind` itself was ending up
      `.bike` for this treadmill. Best explanation found:
      `didDiscoverCharacteristicsFor` set it unconditionally on whichever of
      Indoor Bike Data / Treadmill Data it happened to see *last* in
      `service.characteristics` – an order CoreBluetooth never actually
      guarantees means anything – and this treadmill apparently exposes
      *both* characteristics (likely for compatibility with apps that only
      ever learned to read Indoor Bike Data), making the result a coin flip.
      Fixed by giving Treadmill Data unconditional precedence whenever it's
      present at all, regardless of discovery order – the more specific
      signal, and the one this app has real treadmill-only handling built
      on (the Watch's Walk/Run choice, the treadmill-only metric tiles
      above)
- [x] The trainer features sheet (`TrainerFeaturesView`, the ℹ️ button next
      to the device name) now opens with a new "Reported Characteristics"
      section at the top, listing every characteristic CoreBluetooth
      actually found under the Fitness Machine Service verbatim – not just
      the ones this app reads – each with a best-effort human name
      (`FTMS.characteristicName(for:)`, covering every characteristic the
      Bluetooth SIG's FTMS spec defines) alongside its raw UUID. Direct
      result of not having any way, from inside the app, to see *why*
      `machineKind` detection had gone wrong for the Paragon X above – this
      would have shown the both-characteristics-present situation
      immediately instead of needing several rounds of guessing and a
      symptom-first diagnosis
- [x] New **Speed & Incline** control tab (`ControlMode.speedIncline`),
      treadmill-only – "Power" felt like an odd fit there, where speed and
      incline (not wattage) are normally what a session's actually about.
      Shown only when the connected machine is an actual treadmill
      (`TrainerConnection.machineKind == .treadmill`, not just a device
      that happens to declare the right target features – see the
      `machineKind` fix above for why that distinction matters) *and*
      reports supporting at least one of Speed/Inclination Target Setting
      (`FitnessMachineFeatures.supportsSpeedTarget`/
      `supportsInclinationTarget`, two more individually-typed flags
      alongside the existing Power/Resistance/Grade ones). Sends FTMS op
      codes this app had never used before – Set Target Speed (0x02, UINT16,
      0.01 km/h) and Set Target Inclination (0x03, SINT16, 0.1 %) – verified
      against the Bluetooth SIG spec (section 4.16.2.3/.4) rather than
      guessed, given a wrong encoding here would send a treadmill a
      genuinely wrong physical speed/incline, not just a wrong number on
      screen. Each target clamps to the device's own reported range,
      newly read from the Supported Speed/Inclination Range characteristics
      (0x2AD4/0x2AD5, `TrainerConnection.speedRangeKmh`/
      `inclinationRangePercent`) – the same "ask the device, don't
      hardcode" approach `powerRange`/`resistanceRangeRaw` already used, now
      extended to these two. Unlike every other control tab, this one drives
      two independent targets, not one – `manualControls`' single
      value/+/- pair didn't fit, so it's a separate `treadmillControls`
      view instead, one target group per row, each only shown if the
      connected treadmill actually supports it
- [x] Fixed: connecting could get stuck on "Reading device data …" again,
      this time introduced by the Speed & Incline work above. Two separate
      robustness gaps, found by re-reading the delegate code rather than
      reproducing on hardware first: `didDiscoverServices`/
      `didDiscoverCharacteristicsFor` never actually checked their own
      `error` parameter, so any CoreBluetooth-level failure there left the
      connection silently stuck forever, with nothing to show for it (both
      now transition to `.failed(...)` instead – the exact same failure
      *shape*, if not necessarily the same cause, as the control-point race
      this file already fixed once). And the two new Supported Speed/
      Inclination Range characteristics had been bundled into the same
      `discoverCharacteristics` call as the essential ones (control point
      included) – a device erroring out or behaving oddly discovering
      *these specific, newly-added-today* characteristics could take the
      whole combined request down with it. Split into two independent
      `discoverCharacteristics` calls instead, so a problem with the
      optional pair can no longer block the essential one – worst case now,
      `speedRangeKmh`/`inclinationRangePercent` just stay at their
      placeholder defaults
- [x] Fixed: tapping "Start Workout" pressed the treadmill's own virtual
      "Go" (the FTMS Start/Resume op code) without first (re-)sending the
      target actually showing in the app – it started moving at *its own*
      stored speed/incline instead, ignoring what Unchain displayed.
      `WorkoutSession.start(usingProgram:)` only ever pushed a fresh target
      for Program mode (`sendCurrentWorkoutTarget(for:)`); every manual mode
      (Power/Resistance/Grade/**Speed & Incline**) relied entirely on
      whatever had already been sent earlier – at connect time, or the last
      +/- tap – still being in effect by the time Start was actually
      pressed. Apparently not a safe assumption for at least this
      treadmill: a target set *before* the Start/Resume op code can get
      reset or ignored, with only one sent *after* reliably sticking.
      Fixed with a new `ControlView.startSession()`, replacing all three of
      this view's `session.start(usingProgram:)` call sites (the plain
      phone Start button, the "Walking or running?" dialog's answer, and a
      Watch-triggered bike start) – calls `session.start(usingProgram:)`
      then immediately `sendCurrentTarget()` right after, for every mode,
      not just Program
- [x] Fixed: the remembered control mode (`@AppStorage("lastActiveMode")`)
      could silently, permanently reset to Power on restart – the same bug
      that had apparently already hit Grade earlier, now hitting the new
      Speed & Incline mode too. Root cause: `ensureModeIsAvailable()` ran
      from `.onAppear`, unconditionally – but at that exact moment, right
      after a fresh connect, `connection.machineKind` is still `.unknown`
      and `connection.supportedFeatures` is still `nil` (BLE discovery
      hasn't completed yet), so `availableModes` only ever saw the bare
      minimum (Power/Program/Resistance) at that instant. A restored Grade
      or Speed & Incline preference looked "unavailable" under that
      incomplete picture and got downgraded to Power right then – and
      because `mode` *is* the `@AppStorage`-backed property, that downgrade
      wrote straight to disk immediately, before the real answer had even
      arrived. The existing `.onChange(of: connection.supportedFeatures)`
      safety net couldn't undo it afterwards either: by the time real
      capability data showed up, `mode` already *was* Power – a mode
      that's always available, so the "is the current mode still valid"
      check had nothing left to catch. Fixed by only calling
      `ensureModeIsAvailable()` from `.onAppear` when
      `connection.supportedFeatures` is already known (e.g. this view
      re-appearing on an already-`.ready` connection), leaving the fresh-
      connect case entirely to the `.onChange` handlers – which now also
      include one for `connection.machineKind`, needed since Speed &
      Incline's availability depends on that too, not just
      `supportedFeatures`
- [x] **Structured treadmill workouts from `.zwo` files** (Zwift's XML
      workout format) – the Program tab's treadmill counterpart to `.erg`/
      `.mrc` for a bike. New model, `TreadmillWorkoutProgram`
      (`Unchain/Models/TreadmillWorkoutProgram.swift`) – a genuinely
      separate type from `WorkoutProgram`, not a variant of it, for the
      same reason `GradeProfile` already got its own type rather than
      reusing `WorkoutProgram`: a treadmill needs *two* simultaneous
      targets (speed and incline) per moment, where `WorkoutProgram`
      carries exactly one (power *or* resistance) all the way through its
      chart/session/persistence machinery. `ZWOWorkoutParser`, in the same
      file, is deliberately narrow: only `Warmup`/`SteadyState`/`Cooldown`
      blocks with flat `Pace`/`Incline` attributes (every real file seen so
      far uses these, holding one constant value for the block's whole
      `Duration` – no interpolation needed, unlike `.erg`/`.mrc`'s ramps
      between breakpoints). A genuine Zwift cycling workout (`Power`/
      `PowerLow`/`PowerHigh`, %FTP-based – the same "would need an FTP
      concept for %-based targets" gap `.mrc` already has) or a ramping
      Warmup/Cooldown (`PaceLow`/`PaceHigh`) or repeating interval block
      (`IntervalsT`) all fail with a clear, specific error instead of
      silently producing a wrong or incomplete workout. Verified against
      the exact file that prompted this, parsed standalone with the Swift
      CLI outside the app first (19 segments, correct cumulative timing,
      total duration landing exactly on the file's own stated "45min") –
      not just trusted to compile.
      `TreadmillWorkoutProgramStore` (persistence, the `WorkoutProgramStore`/
      `RouteStore` pattern again) and a new `ActiveWorkout.treadmillProgram`
      case wire it into the same "recent workouts", auto-restore-on-launch,
      and step-transition vibration/interval-sound machinery `.program`/
      `.route` already had – reusing `lastProgramBreakpointIndex` as-is,
      safe since only one `ActiveWorkout` case is ever loaded at a time.
      `.zwo` only ever appears in the file picker/recents for a connected
      treadmill that supports Speed or Inclination targets, the mirror
      image of `.erg`/`.mrc`/`.gpx` being bike-only – so the two groups
      never actually compete, simplifying `loadPersistedOrDefaultProgram`
      down to just picking whichever of all three sources was used most
      recently. Deliberately shipped without a chart for this first
      version – `TreadmillProgramSegmentList` is a plain auto-scrolling
      list of upcoming segments instead, highlighting the current one; a
      genuine dual-axis speed/incline chart, using the same rescale
      technique the heart rate overlay above already established, is a
      reasonable next step, just not one this needed to ship with
- [x] Tapping a row in `TreadmillProgramSegmentList` now jumps playback
      straight to that segment, via a new `WorkoutSession
      .jump(toElapsedSeconds:)`. Not as simple as just assigning
      `elapsedSeconds` – it's recomputed from `startDate` on every refresh
      (see `currentElapsedSeconds(at:)`), so "jumping" it means shifting
      `startDate` itself by the same delta, or the very next tick would
      silently snap it back to the real wall-clock position. Surfaced (and
      fixed) a real edge case while wiring this up: jumping *backward* past
      an already-"finished" position used to leave `isProgramFinished`
      stuck `true` – it had only ever been designed to go false→true, since
      elapsed time was always monotonic before jumping existed. All three
      `sendCurrentWorkoutTarget(for:)` branches (`.program`/`.route`/
      `.treadmillProgram`) now explicitly reset it back to `false` whenever
      a valid position is found, not just implicitly rely on it having
      never been true in the first place. `jump` itself is generic – works
      for any `isDrivenByProgram` workout, not just `.treadmillProgram` –
      though only the treadmill segment list actually calls it today; a
      bike `.program`'s `WorkoutProgramChart` tap-to-inspect only shows
      interval info, doesn't seek, so this wasn't extended there
- [x] **`DeviceListView` now explains itself** to a first-time user instead
      of just showing an empty list: a caption under the scanning spinner
      ("Turn on your trainer or treadmill and keep it within Bluetooth
      range."), plus a footer under each section — Smart Trainer explains
      what the app does at all (FTMS control/monitoring over Bluetooth),
      Heart Rate Strap notes it's optional and that the recorded heart rate
      gets added to the workout's Health app entry on save. Section
      headers switched from the shorthand `Section("title")` initializer to
      `header:`/`footer:` closures to make room for the footer text

## App Store readiness

Unchain has so far been built purely for personal use – sideloaded to one
iPhone via the Makefile's `run`/`debug` targets, no App Store Connect record,
no distribution provisioning. This tracks what's actually left before that
would change, roughly in the order it'd need doing:

- [x] **Privacy manifest** (`Unchain/Resources/PrivacyInfo.xcprivacy`,
      required since 2024 for any "required reason API" usage). Audited by
      grepping the whole app against every required-reason API category
      Apple defines (UserDefaults, file timestamps, system boot time, disk
      space, active keyboard) — only `UserDefaults`/`@AppStorage` turned up
      (every setting: FTP, Max/Resting Heart Rate, Heart Rate Zone
      boundaries, the language override, Vibration/Interval Sound, the
      last-used mode/target values, …). Declares reason **CA92.1**
      ("access user defaults to read and write information that is only
      accessible to the app itself") — confirmed against three independent
      sources after an initial, wrong first answer, since this app has no
      App Group (which would need the different, easily-confused sibling
      reason `1C8F.1` instead). `NSPrivacyTracking: false`, no tracking
      domains – no ads, no analytics, nothing phoned home. Verified by
      inspecting the built `.app`: the file lands at the bundle's top level
      (`Unchain.app/PrivacyInfo.xcprivacy`), which is where Apple requires
      it, not nested under `Resources/`. `NSPrivacyCollectedDataTypes` is
      deliberately *not* declared here – that key exists mainly to
      aggregate third-party SDKs' own manifests (this app has none) and
      doesn't substitute for the actual, separate, mandatory "App Privacy"
      questionnaire in App Store Connect (Health & Fitness data via
      HealthKit, Bluetooth device data) – still to do
- [x] **Privacy Policy URL** – required for any app requesting HealthKit
      access (App Store Review Guideline 5.1.3), and needed for the App
      Store Connect listing itself. Bilingual (English/German) static page
      at `docs/privacy.html`, served via GitHub Pages from this repo's
      `main` branch: **https://607011.github.io/Unchain/privacy.html** –
      states plainly, and truthfully given there's no backend at all, that
      nothing is transmitted to the developer or any third party; Health
      and Bluetooth data both stay on-device, governed by Apple's own
      permission system. Links back to this repo (MIT-licensed, open
      source) as a verifiable claim rather than just an assertion
- [x] **Terms of Use**, at `docs/terms.html` (same bilingual, same GitHub
      Pages site as the privacy policy: https://607011.github.io/Unchain/terms.html) –
      not something Apple strictly requires here (that's Review Guideline
      3.1.2a, scoped to auto-renewable subscriptions; without a custom EULA,
      Apple's own Standard EULA quietly applies and gets linked from the App
      Store page automatically), but worth having anyway since Unchain
      controls real exercise equipment: a plain-language "use at your own
      risk, not medical advice, no warranty, not affiliated with any
      trainer manufacturer" disclaimer that neither the MIT license (covers
      the code, not app usage) nor the privacy policy (covers data, not
      liability) address. Also reachable **from inside the app** now – a
      "Legal" section at the bottom of Settings (`Link`, opens the system
      browser) with both this and the Privacy Policy, so they're not only
      discoverable via the App Store listing
- [x] **Verified Release/Archive build** – a new `make archive` target
      (`xcodebuild archive -scheme Unchain -configuration Release …`, the
      one Makefile target that needs `-scheme` rather than `-target`/`-sdk`,
      since that's all `archive` supports) confirms the app actually
      compiles, links, and code-signs with full `-Os` optimization, not just
      the `-Onone` Debug builds every other target (and CI) has exercised so
      far. Checked past "it compiles": the produced `.xcarchive` has a
      proper `dSYMs/Unchain.app.dSYM` (needed for crash symbolication) and
      `PrivacyInfo.xcprivacy` still lands at the archived app's bundle root.
      One deliberate gap left open: this signs with the automatic
      Development identity/profile already configured for `build`/`run`, so
      it verifies the *build* half only – actually submitting still needs
      Xcode's own "Distribute App" flow (or a hand-written
      `exportOptions.plist` with `method: app-store`) to re-sign with an
      Apple Distribution certificate instead
- [ ] **App name availability** – whether "Unchain" itself is still free on
      the App Store is unchecked; worth confirming before anything else
      below, since a conflict here would ripple into the bundle ID, the
      Marketing/Support URLs' copy, possibly even this README's own title
- [ ] **App Store Connect record** – the actual app listing still needs
      creating from scratch: description, keywords, a deliberately-chosen
      version/build number scheme (currently whatever XcodeGen defaults to,
      `1.0`/`1`), and the age rating questionnaire. Two of its required URLs
      already have somewhere to point, though, both served from the same
      GitHub Pages site as the privacy policy: **Marketing URL** →
      `docs/index.html` (https://607011.github.io/Unchain/), the small
      project landing page; **Support URL** → the privacy policy page
      itself (https://607011.github.io/Unchain/privacy.html), which now
      doubles as one — a "Need help, or found a bug?" card right under the
      privacy summary links to GitHub Issues and the contact email, in both
      languages, so it actually reads as a support page and not just
      repurposed legal text
- [ ] **Screenshots** – for every required device size (at minimum a
      6.7"-class iPhone; iPad too, since the app explicitly supports Split
      View) – none exist yet
- [ ] **App Store Connect's "App Privacy" questionnaire** – a separate,
      mandatory, web-based step (distinct from the local
      `PrivacyInfo.xcprivacy` manifest above, which doesn't substitute for
      it) declaring what's collected for Apple's own "nutrition label" –
      Health & Fitness data via HealthKit, roughly. The actual privacy
      policy page already documents exactly what's read/written, which
      should make answering this fast
- [ ] **A real Distribution-signed build, uploaded** – `make archive`
      (above) only verifies the build compiles and signs with the automatic
      *Development* identity; actually submitting needs Xcode's own
      "Distribute App" flow (or a hand-written `exportOptions.plist` with
      `method: app-store`) to re-sign with an **Apple Distribution**
      certificate, then upload via Xcode Organizer or Transporter
- [ ] **Export compliance questionnaire** – comes up on every upload;
      standard BLE/HTTPS encryption usually qualifies for the common
      exemption, but the question still has to be answered each time
- [ ] *(recommended, not required)* **TestFlight beta** before a public
      release – so far only ever run against one trainer and one iPhone;
      broader FTMS device compatibility is unverified
- [ ] *(recommended, not required)* **Crash reporting** – zero visibility
      into post-launch crashes otherwise
- [x] **Watch app icon looked too small** after the chain-link redesign –
      correctly sized on the iPhone Home Screen, but visibly smaller/lighter
      on the Watch. watchOS pads its circular icon mask more aggressively
      than iOS pads its squircle, and the new glyph's content didn't reach
      as close to the edges as the old arrow-based design did, so the same
      1024×1024 asset that worked fine for iOS read as shrunken there. Fixed
      with a watchOS-only variant, `assets/Icon-Watch.svg` – the same glyph
      uniformly scaled up ~16 % around its own center (which, as a side
      effect, thickens the strokes too, helping legibility at the Watch's
      much smaller physical icon size) – checked to stay just inside the
      circular safe area (max radius ≈ 95 % of the canvas half-width, so
      nothing gets clipped by the mask) rather than picking a scale factor
      by eye alone. The iPhone/docs icon is untouched, since only the Watch
      one was reported as wrong.
- [x] **CI badge** at the top of README.md, linking to the `ci.yml` GitHub
      Actions workflow run history
- [x] Real-workout feedback from a walking session, all in `ControlView`:
      the `HeartRateZonesView` zone-duration labels (shared by bike and
      treadmill, live and post-workout) were hard to read mid-workout at a
      glance – bumped ~50 % (15→23pt regular width, 10→15pt compact).
      `TreadmillProgramSegmentList`'s interval rows had three different
      text treatments (small gray duration, default-styled speed, gray
      incline) for no real reason – all three now share one plain style.
      The left-hand duration for the *current* segment now counts down in
      1-second steps (`elapsedSeconds`-driven, same ticking source as
      everything else on screen) instead of showing a static total – other
      rows still show their plain total, since counting down a segment
      that hasn't started yet wouldn't mean anything. And the current
      row's highlight is now a genuine left-to-right progress bar for that
      segment (a light full-row wash plus a more saturated overlay whose
      width tracks `progressFraction(for:)`), not just a flat single-color
      background
- [x] Fixed: tapping a row in `TreadmillProgramSegmentList` to jump used to
      make the overall elapsed-time display jump too, forward or backward,
      instead of continuing to count real walked/run time. Root cause was
      `WorkoutSession.jump(toElapsedSeconds:)` shifting `startDate` itself
      – which `elapsedSeconds` is recomputed from every refresh – so a
      preview jump permanently redefined "how long has this workout been
      running" along with "where is playback". Introduced a separate
      `programOffsetSeconds` (and public `programPositionSeconds =
      elapsedSeconds + programOffsetSeconds`): `jump` now only moves the
      offset, `elapsedSeconds` itself is never touched by it again.
      `sendCurrentWorkoutTarget(for:)`'s `.program`/`.treadmillProgram`
      cases, the segment list, and `treadmillProgramTargetLabel` all read
      `programPositionSeconds` (so jumping still changes which segment is
      current/highlighted and what target gets sent); every other elapsed-
      time consumer (the on-screen clock, `powerHistory`/`heartRateHistory`
      timestamps, the final `WorkoutSummary.activeDuration`) keeps reading
      `elapsedSeconds`, so those can no longer be corrupted by a jump
      either – previously latent, since nothing exercised it this way yet
- [x] **New Settings → Devices section** – every trainer this app has ever
      connected to (`TrainerDeviceStore`, plain `UserDefaults`, keyed by
      `CBPeripheral.identifier` – same stable-across-launches ID
      `BluetoothManager` already relies on for the last-used HR strap),
      grouped into Treadmills/Bike Trainers, no live connection required to
      see or open one (`ControlView` records a device the moment
      `machineKind` resolves, in the existing `.onAppear`/`.onChange(of:
      connection.machineKind)` handlers). Tapping a row opens a new
      `TrainerDeviceSettingsView` for that specific device – for now, just
      one treadmill-only setting, seconds-per-degree incline response time
      (`TrainerDeviceSettings.inclineChangeSecondsPerDegree`, persisted per
      device ID). Nothing reads this value yet – it's prep for a next step,
      compensating `.zwo` incline changes for how long a given treadmill
      actually takes to physically get there. Bike trainers get a plain
      "nothing here yet" placeholder rather than an empty screen, since
      there's no equivalent setting for them so far
- [x] **That next step**: reported from real use – jumping straight from a
      steep incline at a slow pace to flat at a fast one (e.g. 15 % at
      4 km/h to 0 % at 6.5 km/h) used to send both targets at once. The
      belt speeds up almost instantly; the incline motor takes real,
      measurable time to physically get there – for those few seconds the
      rider was doing 6.5 km/h on a platform still tilted close to 15 %,
      enough to push someone off the back. `WorkoutSession
      .sendCurrentWorkoutTarget(for:)`'s `.treadmillProgram` case now
      ramps *speed* linearly across a `.zwo` interval boundary, over the
      incline's own estimated travel time (`|Δ incline| ×
      TrainerDeviceSettings.effectiveInclineChangeSecondsPerDegree`, the
      per-device setting added above – `1.0` s/° assumed for any
      unmeasured treadmill, per instruction, rather than `0`, which would
      silently skip ramping altogether). Incline itself is still sent as
      one flat target immediately, same as before – nothing here controls
      how fast the motor itself moves; this only paces how fast the belt
      gets ahead of it. A tick partway through an already-running ramp
      keeps interpolating from wherever the belt actually last was
      commanded to (`lastSentTreadmillSpeedKmh`/`lastSentTreadmillInclinePercent`),
      not the old segment's nominal target, so a second transition
      arriving before the first ramp finished still continues smoothly.
      Initially left a manual `jump(toElapsedSeconds:)` (the segment-list
      tap-to-jump) out of this entirely, reasoning it was "just a preview" –
      wrong: `jump` only works while the workout is actually running or
      paused, so whatever it lands on is being walked/run on for real, and
      the treadmill's incline motor doesn't know or care whether a target
      change came from ordinary playback or a tap. Fixed the same day, once
      asked to justify it (#diskussion) – added a separate
      `pendingTreadmillSpeedRampRestart` flag so `jump` still restarts the
      ramp toward wherever it landed, while keeping its existing,
      unrelated suppression of vibration/interval-sound (via
      `lastProgramBreakpointIndex = nil`, so a big skip doesn't fire a
      burst of buzzing for every entry jumped over) untouched
- [x] **Local workout history, independent of Apple Health** – every
      finished workout is now saved on-device regardless of what (if
      anything) also gets saved to Health, so declining/skipping Health
      never means losing the workout:
  - New `WorkoutRecord`/`WorkoutSample` (`WorkoutHistoryStore.swift`) –
    richer than the transient `WorkoutSummary` a live session hands to the
    post-workout dialog, since it also carries a real per-second
    heart-rate/power/speed trace (`WorkoutSession.mergedWorkoutSamples()`,
    merging the session's own `powerHistory`/`heartRateHistory` with a new
    `speedHistory` – added purely for this, previously nothing tracked a
    live speed *time series*, only the running total `distanceMeters`).
    `HeartRateZone` gained `Codable` conformance for this (was
    `Int, CaseIterable, Identifiable` only).
  - `WorkoutHistoryStore` persists one JSON file per workout under this
    app's own Application Support directory (`FileManager`, plain
    read/write/delete – deliberately not `UserDefaults`, which doesn't
    scale to a growing history of per-second samples, and not the
    Documents directory either, which would surface raw JSON in the Files
    app for no reason – `.tcx` export is the actual "get it out of the
    app" path). No new `PrivacyInfo.xcprivacy` entry needed – plain file
    I/O isn't one of Apple's required-reason API categories, unlike
    `UserDefaults`.
  - **Where it hooks in**: not `WorkoutSession.stop()` – that can still be
    undone via `cancelStop()` (the confirmation dialog's own Cancel
    button) – but `reset()`, the one place every path that actually
    *keeps* a stop (Save to Health, Discard, and the silent
    Watch-companion one) all funnel through regardless of the Health
    decision.
  - New `TCXExporter.swift` – hand-built XML (no library; the document
    shape is small and fixed enough not to need one), producing a
    Trackpoint per stored sample with `HeartRateBpm` and a Garmin `TPX`
    extension (`Speed` in m/s, `Watts`) wherever each is actually present.
    Per-trackpoint `DistanceMeters` is integrated after the fact from the
    stored speed trace – the same `speed × Δt` approach
    `WorkoutSession.refreshWorkoutState` already uses live, just replayed
    from `samples` instead of BLE notifications. `Sport` maps
    bike→"Biking", treadmill→"Running" (TCX has no Walk/Run distinction
    either, matching FTMS itself), unknown→"Other"; `Calories` (required
    by the schema) reuses the existing cycling kJ≈kcal estimate when
    available, `0` otherwise – same "no accurate figure means no invented
    one" rule as `liveActiveEnergyKcal`.
  - New `WorkoutHistoryView.swift` – a list of saved workouts (swipe to
    delete) reached from a new "Workout History" button in `SettingsView`,
    same placement as "Log a Workout…"/"Diagnostics"; tapping one opens a
    detail screen with the summary stats, `HeartRateZonesView` (now
    non-`private` in `ControlView.swift`, reused here the same way
    `InfoButton` already is) if zone data exists, and a `ShareLink` for the
    `.tcx` export, written to a temp file purely so the share sheet has a
    real file `URL` to hand off
- [x] Fixed: connecting to a treadmill loaded the last-used *bike* program
      instead of the last `.zwo` treadmill workout – the same bug shape as
      the earlier remembered-control-mode fix, just found later, in
      `loadPersistedOrDefaultProgram()` instead of
      `ensureModeIsAvailable()`. It ran unconditionally from `.onAppear`,
      which fires the instant `ControlView` is pushed – before
      `connection.machineKind`/`supportedFeatures` have resolved (both
      start `.unknown`/`nil`, settling only once the trainer's own
      characteristics are actually read back over BLE). That early,
      `compatibleRecents` evaluates empty regardless of what's actually
      connected (every filter in it checks `machineKind`), so it fell
      through to `supportsPowerTarget`'s `?? true` default and silently
      loaded the bundled power-based ramp test – on a treadmill, *every*
      time, not just occasionally, since `machineKind` is guaranteed
      `.unknown` at that exact moment. Worse, once that wrong program
      landed, the function's own `activeWorkout == nil` guard then
      permanently blocked correcting it, even after the real capabilities
      arrived moments later. Fixed with a new
      `loadPersistedOrDefaultProgramIfCapabilitiesKnown()` guard, called
      from `.onAppear` only when both are already known plus the same two
      `.onChange` handlers `ensureModeIsAvailable()` already used for
      exactly this reason
- [x] `TrainerFeaturesView`'s "Reported Characteristics" section now shows
      the device's own actual value under the four "Supported … Range"
      rows (0x2AD4 Speed, 0x2AD5 Inclination, 0x2AD6 Resistance Level,
      0x2AD8 Power) instead of just the bare characteristic name/UUID –
      `TrainerConnection` already parses all four
      (`speedRangeKmh`/`inclinationRangePercent`/`powerRange`/
      `resistanceRangeRaw`), just wasn't showing them here yet. Resistance
      reuses the same ×0.1-native-unit, no-suffix formatting
      `ControlView.formattedResistanceRange` already uses for this exact
      range elsewhere, so the two never read differently for the same
      device
- [x] **New device setting: Start Countdown (seconds)** – some treadmills
      count down on their own console ("3, 2, 1, go") after receiving
      Unchain's Start/Resume command, before the belt actually starts
      moving; without accounting for that, the app's displayed elapsed
      time (and, following it, the `.zwo` program's own target-sending)
      runs ahead of the treadmill by however long that countdown takes.
      `WorkoutSession.start(usingProgram:)` now sets `startDate` into the
      *future* by `TrainerDeviceSettings.effectiveStartCountdownSeconds`
      (default `0`, unlike the incline setting's conservative non-zero
      default – plenty of treadmills react immediately, and assuming a
      countdown that isn't real would introduce a new sync error instead
      of fixing one) rather than to `Date()` directly –
      `currentElapsedSeconds(at:)` already clamps a negative
      `now.timeIntervalSince(startDate)` to `0`, so `elapsedSeconds`
      (and `programPositionSeconds` through it) simply holds at `0`,
      i.e. the workout program doesn't start *advancing*, until real time
      catches up – no new state needed. `startTracking()`'s existing
      paused-interval folding (used by `resume()`/`cancelStop()`, both of
      which send another Start/Resume too) gets the same countdown added,
      so resuming from pause is covered the same way
- [x] **Ongoing clock-sync against the connected machine's own elapsed
      time** – the Start Countdown fix above got the two clocks close
      (~0.5 s apart) right at the start of a workout, but they were still
      about 4 seconds apart after 48 minutes: `elapsedSeconds` is computed
      purely from the iPhone's system clock (`Date()`), while the machine
      keeps its own, independent timer – even a small relative *rate*
      difference between the two compounds over a long workout, unlike a
      fixed offset. FTMS's data characteristics optionally report the
      device's own Elapsed Time field (whole seconds, counted from
      whenever it actually started moving) – previously parsed only far
      enough to *skip* it on the way to Power, if parsed at all. **This
      entry describes the first version shipped; a later entry below
      ("Fixed a real crash…") replaces its mechanism entirely after a real
      crash surfaced a flaw in it – read that one for the design Unchain
      actually ships with.** First version: read into a new
      `TrainerMetrics.treadmillElapsedSeconds`, with
      `WorkoutSession.refreshWorkoutState` re-anchoring `startDate` to
      match it on every refresh whenever reported – the same
      `startDate`-shifting trick `jump(toElapsedSeconds:)` already uses,
      just driven by the trainer's own live feedback instead of a tap.
- [x] **Estimated VO2max** in `WorkoutHistoryDetailView`, for a `.zwo`
      treadmill program with a genuinely held `SteadyState` segment –
      prompted by realizing Unchain already has everything the Heart Rate
      Reserve estimation method (ACSM's Guidelines for Exercise Testing and
      Prescription) needs: Resting Heart Rate (Health), age-predicted Max
      Heart Rate (Tanaka formula, already prefilled in `SettingsView`), and
      – now that `.zwo` incline is tracked live – a known, held pace and
      grade to compute submaximal VO2 from via the ACSM walking/running
      metabolic equations (same family `EnergyEstimator
      .walkRunActiveEnergyKcal` uses, with the grade term that one omits
      – no live incline reaches it there – kept in the new
      `VO2MaxEstimator`). Body weight and biological sex turned out *not*
      to actually be needed for this – Unchain doesn't even read
      biological sex from Health at all, contrary to the assumption that
      prompted this. New `TreadmillSegmentKind` (`.warmup`/`.steadyState`/
      `.cooldown`) on `TreadmillWorkoutSegment`, populated by
      `ZWOWorkoutParser` from which `.zwo` element a segment came from –
      previously discarded once parsed – lets `VO2MaxEstimator` find the
      longest genuinely-`SteadyState` block (≥3 minutes) and use only its
      *settled* heart-rate window (skipping the first 90s/half, whichever
      is more) rather than an unsettled reading. Made `Optional` rather
      than required, so a `.zwo` program saved to `TreadmillWorkoutProgramStore`
      before this existed still decodes – it just never qualifies, instead
      of the whole recents list failing to load. Walking vs. running ACSM
      equation is picked per-segment by speed (≥8 km/h, the classic
      walk-to-run crossover), not from the one-time "Indoor Walk"/"Indoor
      Run" choice at Start, which `WorkoutSession` doesn't track anyway and
      which a single `.zwo` program's own segments can easily cross (e.g. a
      brisk uphill interval within an otherwise easy walk). Clearly labeled
      as an estimate (±10–15 % off a lab result is typical for this
      method) with an `InfoButton` explaining the method; never written to
      HealthKit, per instruction – too uncertain a number to silently feed
      into Health's own Cardio Fitness trend
- [x] **Workout Builder** (`docs/builder.html`, linked from the landing
      page) – a browser-based companion tool, prompted by trying several
      web workout builders and finding them all tedious to use (fill in a
      table row by row, or click prefab blocks together). Instead: drag
      across a grid of discrete time intervals (30 s/60 s/5 min, or any
      count) to *draw* a target profile freehand, like an automation lane
      in a DAW – dragging fast between two intervals linearly interpolates
      the ones skipped over, so it draws smooth ramps, not just flat
      steps. Two profile modes – Bike (Power) and Treadmill (Speed &
      Incline) – deliberately not a bike Grade/elevation profile too: a
      *time*-indexed grid only makes sense for a target a trainer holds
      for a fixed duration regardless of effort (ERG-mode power, or a
      treadmill's motor-driven belt speed) – simulated grade is
      *distance*-indexed (how long a "climb" lasts depends on how fast the
      rider actually climbs it), which is exactly why `GradeProfile` is
      GPX/distance-based in the app itself, not time-based. Exports
      `.erg`/`.mrc`/`.zwo`, hand-written to match this repo's own
      `WorkoutProgramParser`/`ZWOWorkoutParser` byte-for-byte (`.mrc` via
      the same `FTP = <value>` header convention the app's own parser
      already reads); adjacent equal-value intervals merge into one
      `.zwo` block rather than emitting one tiny segment per interval.
      Adjustable Warm-up/Cool-down interval counts tag the first/last
      stretch as `<Warmup>`/`<Cooldown>` instead of `<SteadyState>` (shown
      as a shaded band on the chart) – lets the *rest* of the workout
      correctly qualify as `SteadyState` for the app's own VO2max
      estimate above. No account, no upload, no build step – a single
      static HTML file, generated/prototyped first as a Claude Artifact to
      test the drag feel before committing it to the repo; the app's icon
      (`docs/assets/icon.png`, already used by the landing page) appears
      small and corner-rounded next to the title, consistent with but
      distinct from the landing page's own larger treatment
- [x] Fixed: dragging (not just clicking) on the Workout Builder's grid
      didn't work – `renderLane()` cleared and rebuilt the *entire* `<svg>`
      on every single painted value, including the invisible hit-rect
      pointer events land on, which destroys `setPointerCapture` the
      instant its element leaves the DOM (per spec). Only the initial
      click's `pointerdown` ever painted anything; every subsequent
      `pointermove` (the actual drag) went nowhere. Fixed by splitting
      each lane into a persistent interaction layer (hit-rect + listeners,
      set up once) and a separate `<g>` for the redrawn visuals (grid,
      curve, bands) that `renderLane` clears and rebuilds freely without
      ever touching the interaction layer; capture now also lives on the
      hit-rect itself, not the ancestor `<svg>` (capturing there moved the
      event *target* away from `hit`'s own listeners, which don't receive
      events bubbling from a descendant they aren't one).
- [x] Warm-up/Cool-down are now also draggable directly on the chart – a
      small notched grip on the shaded boundary, not just the small
      stepper fields in the toolbar (real, but easy to miss and not
      obviously tied to the shading once found – reported as "not
      intuitive"). Only on the primary lane per mode (Power for bike,
      Speed for treadmill) – both counts are shared across every lane in a
      mode, so a second draggable boundary on the Incline lane would just
      be a redundant, confusing second way to move the same one
- [x] **Workout Builder: localStorage restore + an editable, parsed preview**
      – two follow-up requests once the tool itself was working well:
  - The last-edited workout now survives a reload –
    `localStorage.setItem`/`getItem` under `interval-sketch-state-v1`,
    written (best-effort, wrapped in `try`/`catch` – private browsing or a
    disabled store just means it doesn't persist, not a crash) after every
    state-changing action via `updatePreview()`'s own end, and read back
    at startup in place of the bundled sample profiles when present. No
    account, no server – exactly this page's whole point, matching
    Unchain's own "no login" stance.
  - The `<pre>` preview became a real `<textarea>`, and typing or
    **pasting** into it now parses back into the chart – for `.erg`/`.mrc`
    via a from-scratch reader of `[COURSE DATA]`'s `minutes value` rows,
    resampled onto the current bin grid as a piecewise-linear curve (the
    same interpretation `WorkoutProgram.target(atElapsedSeconds:)` gives
    these files in the app itself, so *any* valid file works, not just
    ones this tool generated); for `.zwo` via `DOMParser` (real XML
    parsing, not regex) reading `Warmup`/`SteadyState`/`Cooldown`
    elements – `sportType` even auto-switches the Bike/Treadmill toggle.
    A 400 ms debounce avoids re-parsing every keystroke; a small status
    line next to the preview label shows "✓ synced to chart" or, on a
    parse failure, why – the chart itself is left untouched rather than
    breaking on a bad edit. Deliberately never calls `updatePreview()`
    from this path (only `renderAll()`) – regenerating the canonical text
    mid-edit would overwrite the rider's own typing and reset the caret;
    the next chart-side action (painting, a toolbar control) resyncs the
    textarea normally.
- [x] **Estimated VO2max also shown right after the workout**, in
      `SavedWorkoutSummaryView` under the heart rate zone bar – requested
      while actively iterating on VO2max test protocols, so checking the
      result doesn't need a trip to Workout History every time. New
      `WorkoutSession.estimatedVO2MaxForCurrentWorkout()` – a public
      wrapper around the same private computation `reset()` itself uses to
      save into `WorkoutHistoryStore` – has to be called from `ControlView
      .save(_:as:)` *before* `session.reset()` runs, since `reset()` is
      what clears the raw samples/`activeWorkout` it reads; captured into
      a new `savedWorkoutVO2Max` alongside `savedSummary` for exactly that
      reason, rather than trying to read it from (by then already reset)
      session state once the sheet actually appears.
- [x] **Fixed a real crash**, reported right after a long (~28 min) VO2max
      test run – then, once the fix exposed how convoluted the original
      design was, replaced that design outright rather than just patching
      around the bug. The crash: the treadmill clock-drift correction (see
      the entry above) could step `elapsedSeconds` *backward* – if the
      iPhone's clock was already running ahead by several seconds when the
      correction landed (more likely the longer a workout runs), the shift
      needed to resync could exceed a whole second in one go.
      `powerHistory`/`heartRateHistory`/`speedHistory` each dedupe by
      comparing a new sample only against their own *last* entry, which
      assumes `elapsedSeconds` never goes backward – a single backward
      step reintroduced an already-recorded second once forward ticking
      resumed, and `mergedWorkoutSamples()` (freshly exercised by the
      previous entry's `estimatedVO2MaxForCurrentWorkout()`, which is
      exactly what was running at the moment of the crash) builds a
      `Dictionary` from these arrays that fatal-errors outright on a
      duplicate key.
      - First fix attempt: keep nudging `startDate`, but only when doing so
        wouldn't step `elapsedSeconds` backward – i.e. skip a
        would-be-regressive correction instead of applying it. Wrong, on
        reflection: since the iPhone's clock genuinely running fast
        relative to the treadmill's is the whole premise of this feature,
        that version would've blocked *every* subsequent correction for
        the rest of the workout the first time it triggered once, not just
        the one problematic tick.
      - Second attempt: target `max(treadmillElapsedSeconds,
        elapsedSeconds)` instead of the reported value directly, so a
        behind-published reading makes `elapsedSeconds` *hold* (not
        advance, but not regress either) rather than being skipped
        outright – converges correctly instead of getting stuck. Correct,
        but asking "wait, shouldn't the app just show what the device
        itself sends?" while reviewing it exposed that the whole
        `startDate`-nudging mechanism this was built on was more
        complicated than it needed to be – and had its own quiet,
        previously-unnoticed side effect: shifting `startDate` also
        shifts the workout's own reported *start time* (`stop()` uses it
        for `WorkoutSummary.startDate`, which becomes the Health workout's
        start timestamp), which a display-sync feature had no business
        touching at all.
      - **Final design – the drift-correction mechanism is gone
        entirely**: `refreshWorkoutState` now publishes the device's own
        `deviceElapsedSeconds` *directly* as `elapsedSeconds` whenever it's
        available (via `max(deviceElapsedSeconds, elapsedSeconds)`, the
        same never-regress guarantee as before, just applied to the
        published value instead of to `startDate`), falling back to the
        local `startDate`-based `currentElapsedSeconds(at:)` only when
        nothing's reported (or not yet). That local computation remains
        the gate for *whether* to trust the device's value at all: only
        once it itself shows genuine forward progress since the last
        refresh (`localElapsedSeconds > elapsedSeconds`) – i.e. once
        whichever countdown hold is active, if any, has actually lifted.
        Covers both `start()`'s own initial countdown and a post-`resume()`
        one (folded into `totalPausedDuration`) without needing to know
        which kind is active, and stays correct even if a given machine's
        own elapsed-time counter runs through its console countdown rather
        than only once it's actually moving. `pause()`/`stop()` no longer
        blindly recompute `currentElapsedSeconds()` either – `max(...)`
        against the already-published value, so they can't regress below
        a device-sourced reading either.
      - **Generalized beyond treadmills while at it**: prompted by
        realizing Indoor Bike Data (0x2AD2) has its own optional Elapsed
        Time field too (bit 11), same as Treadmill Data's – previously
        never parsed at all for bike. `TrainerMetrics.treadmillElapsedSeconds`
        renamed to `deviceElapsedSeconds` and now populated from both
        `init(data:)` and `init(treadmillData:)`, so any bike trainer that
        happens to report it benefits from the same direct-trust sync, not
        just treadmills.
      - Defense in depth, kept regardless: `mergedWorkoutSamples()` builds
        its three dictionaries with `Dictionary(_:uniquingKeysWith:)`
        (keeps whichever duplicate is last) instead of
        `Dictionary(uniqueKeysWithValues:)` (fatal-errors on any
        duplicate) – so a *different*, not-yet-known cause of a duplicate
        `timeSeconds` would degrade gracefully instead of crashing, rather
        than relying solely on the one cause that's now fixed at the
        source.
- [x] **Warns if a loaded workout's targets exceed this trainer's own
      range** – `setTargetPower`/`setTargetSpeed`/`setTargetInclination`
      already clamp silently regardless (each to `connection.powerRange`/
      `speedRangeKmh`/`inclinationRangePercent`), so the *sent* target
      itself was never unsafe; the gap was purely that the rider had no
      way to *know* up front that a file built for a different, more
      capable machine would be adjusted – a target number that stopped
      matching the file partway through a workout was the only sign
      anything had happened. (One genuinely unsafe consequence of the same
      unclamped-target gap did turn up, for `.zwo` treadmill programs
      specifically – see the very next entry below, found while writing
      this one.) `ControlView.loadProgramIntoSession(_:)`/`loadTreadmillProgramIntoSession(_:)`
      – already the one funnel every load path (auto-restore, file import,
      sample button, recent-workouts tap) goes through – now also call a
      new `warnIfOutOfRange(_:)`, comparing the *whole* file's min/max
      target(s) against the connected trainer's current range and, if
      either falls outside it, setting a new `rangeWarning` alert
      ("Some Targets Will Be Adjusted") explaining the workout can still
      be followed in full, just with out-of-range targets capped to
      whatever this trainer actually supports. `.power`-kind `.erg`/`.mrc`
      programs are checked against `powerRange`; `.zwo` treadmill programs
      against `speedRangeKmh` and `inclinationRangePercent` together, with
      three distinct message variants (speed only / incline only / both)
      rather than one generic one. `.resistance`-kind programs are
      deliberately exempt: their 0–100 % values are already relative to
      whatever the trainer itself supports (see
      `setTargetResistancePercent`'s own doc comment), so they can never
      be "out of range" to begin with – only `.power`'s absolute watts
      can exceed what one *specific* trainer happens to support. GPX
      routes are exempt too, for the opposite reason: `setSimulationGrade`
      clamps to a fixed ±25 % safety margin, not a device-reported range –
      there's no FTMS "supported grade range" characteristic to compare
      against in the first place.
- [x] **Fixed a real, physical consequence of the same unclamped-target
      gap**: `sendCurrentWorkoutTarget(for:)`'s treadmill speed ramp (see
      the "belt getting ahead of the incline motor" entry further above)
      computed how long the ramp should take from the incline delta
      between the *file's own, raw* targets – e.g. a `.zwo` segment
      transition from 10 % to an unsupported -6 % read as a 16-percentage-
      point move. But the incline motor was only ever going to travel the
      *real*, clamped distance – down to whatever this treadmill's own
      `inclinationRangePercent` actually bottoms out at, e.g. 0 %, a
      10-point move, not 16. The ramp duration came out too long for the
      incline change that was actually going to happen, so the belt sat at
      an intermediate speed for far longer than the incline motor itself
      needed to reach where it was actually headed. Fixed by clamping the
      segment's own target incline to `connection.inclinationRangePercent`
      once, up front, and using that clamped value everywhere afterward –
      the delta the ramp duration is computed from, what's actually sent
      via `setTargetInclination(percent:)` (identical to what it would've
      clamped to internally anyway, just computed once instead of
      implicitly), and what `lastSentTreadmillInclinePercent` remembers as
      "where the incline motor actually is now" for the *next* segment's
      own delta. That last one matters on its own: before this fix,
      `lastSentTreadmillInclinePercent` stored the raw file value even
      when the belt could never have actually reached it, so an *already*
      wrong starting point kept compounding into every subsequent ramp's
      own delta too, not just the one segment that first exceeded the
      range.
- [x] **Fixed a real false positive in the range-warning check above**:
      connecting to a Kickr Core (genuinely supporting 0–2000 W) with a
      ~700 W workout loaded triggered the "some targets will be adjusted"
      warning anyway – `warnIfOutOfRange(_:)` ran before this specific
      trainer's own "Supported Power Range" (0x2AD8) answer had actually
      come back over BLE, so it compared against `TrainerConnection
      .powerRange`'s placeholder 25...400 W default instead of the real
      range – the exact risk that entry's own doc comment already
      flagged as a caveat, now confirmed as a real bug rather than a
      theoretical one. The race is inherent, not something a fixed delay
      could paper over: `didDiscoverCharacteristicsFor` fires off reads
      for Fitness Machine Feature, machine kind (via the data
      characteristic's own first notification), and all four Supported
      Range characteristics essentially at once, and CoreBluetooth
      gives no ordering guarantee whatsoever across their independent
      async callbacks – `loadPersistedOrDefaultProgramIfCapabilitiesKnown()`
      (the auto-restore path that loaded this particular workout) was
      already guarded against running before `machineKind`/
      `supportedFeatures` specifically had resolved, but not against the
      four Supported Range characteristics, which can just as easily
      resolve after either of those two. New `TrainerConnection
      .hasReceivedPowerRange`/`hasReceivedSpeedRange`/
      `hasReceivedInclinationRange` – set the instant *any* response for
      the matching characteristic arrives, even a malformed one that
      doesn't itself update the range – let `warnIfOutOfRange(_:)` tell
      "this device's real, reported answer" apart from "still just the
      placeholder default", which the range value alone can't: a device
      could always legitimately report exactly the placeholder's own
      numbers as its real range too. Skipped entirely (no warning) while
      the relevant flag is still `false`, rather than risk another false
      positive against a guess; a new matching trio of `.onChange(of:)`
      handlers re-runs the check against whatever program is currently
      loaded once each range's real answer *does* arrive, so a genuine
      out-of-range workout still gets flagged, just possibly a moment
      later than before instead of immediately but sometimes wrongly.
      The treadmill version's two checks (speed, incline) are gated on
      their own flag independently, not on both arriving together – a
      treadmill that never answers one of the two characteristics at all
      would otherwise permanently silence a genuine finding on the other
      too.
- [x] **Device screen now also shows previously-connected trainers that
      are currently out of range**, grayed out with a "Not in Bluetooth
      Range" label above the name, rather than a used-before trainer just
      silently vanishing from the list the moment it's out of range or
      switched off – requested after finding it disorienting not to see a
      familiar trainer there at all while setting up. Reuses
      `TrainerDeviceStore` (already recording every trainer ever connected
      to, for `SettingsView`'s own per-device settings list) rather than
      adding a second "known devices" store – `DeviceListView`'s new
      `outOfRangeTrainerDevices` is just `TrainerDeviceStore.loadAll()`
      minus whatever `bluetooth.trainerDevices` already has live, reloaded
      on every appearance same as `SettingsView.knownDevices` already is.
      Purely informational, not a `Button` – there's nothing to actually
      do with an unreachable device yet (a tap-to-wait-and-auto-connect
      once back in range, the way the heart rate strap already does off
      `lastHeartRateStrapUUIDKey`, would need `TrainerDeviceStore` to grow
      well beyond its current "just for grouping settings" scope). Scoped
      to the Smart Trainer section only for now – Heart Rate straps work
      differently already (one remembered device, always actively trying
      to reconnect via `attemptAutoReconnectHeartRateStrap()`/discovery-
      time matching, not a static list to grey out entries from).
- [x] **Record a freely-ridden `.power`/`.resistance`/`.speedIncline`
      session's own target schedule, and offer to save it as a portable
      `.erg`/`.mrc`/`.zwo` file** – so a good freeride/impromptu run is
      repeatable later, not just logged. Deliberately excludes `.grade`:
      neither `.erg`/`.mrc` (power/resistance only) nor `.zwo` (speed/
      incline only, and machine-kind-locked to treadmill throughout this
      app – its own "export" could never even be loaded back into a bike)
      have anywhere to put a recorded simulation grade, and forcing it
      into either format regardless would produce a file that looks
      portable but isn't. Recording always runs in the background for the
      whole `.running`/`.paused` duration of an eligible session, rather
      than needing a separate "start recording" toggle the rider could
      forget – whether to actually keep it as a file is decided afterward,
      in the post-Stop dialog, alongside the existing Health/Discard
      choice, not up front.
      - `WorkoutSession.RecordedManualProgram` – `.program(WorkoutProgram)`
        or `.treadmillProgram(TreadmillWorkoutProgram)`: the recorder
        reuses the exact same model types a *loaded* file already parses
        into, rather than inventing a parallel representation, so a
        recording is exported via their existing `fileContents()`
        (`TreadmillWorkoutProgram` gained its own – the write-side
        counterpart to `ZWOWorkoutParser`, previously read-only – writing
        every segment as a flat `SteadyState` block, which is exactly what
        an untagged one would parse back into anyway) and could equally be
        fed straight back into `loadProgram(_:)`/`loadTreadmillProgram(_:)`
        to repeat it.
      - New `WorkoutSession.beginRecordingManualTarget(kind:value:)`/
        `beginRecordingTreadmillTarget(speedKmh:inclinePercent:)`, called
        once from `ControlView.startSession()` right after
        `start(usingProgram:)`, open the recording with whatever target is
        already showing as its first breakpoint/segment (`t = 0`); neither
        gets called at all for `.grade`/`.program`, so
        `recordedProgramForCurrentWorkout()` naturally stays `nil` for
        those – no separate "is this recordable" flag needed anywhere.
      - `recordManualTarget(value:)`, called from `step(_:)` on every
        `.power`/`.resistance` `+`/`-` tap, appends *two* breakpoints at
        the current elapsed time (the old value closing off, the new one
        starting) rather than one – `WorkoutProgram`'s own linear-
        interpolation-between-breakpoints rule means a single new point
        would ramp smoothly from the old value to the new one instead of
        stepping; two points at the same time is the same "flat step"
        convention every `.erg`/`.mrc` file already relies on.
        `recordTreadmillTarget(speedKmh:inclinePercent:)`, called from
        `stepSpeed(_:)`/`stepIncline(_:)` with *both* current targets
        every time (a `TreadmillWorkoutSegment` always carries both, even
        though each stepper only actually changes one), doesn't need that
        trick – closes the currently open segment off at the new elapsed
        time and opens a fresh one, since a segment is already flat over
        its own `duration` by construction.
      - `recordedProgramForCurrentWorkout()`, called from `reset()` itself,
        closes off whatever's still open at the actual stop time – without
        this, the file's own duration would end at the *last change*
        rather than however long that final value was actually held for,
        since both models derive their duration from their own last
        entry.
      - **Redesigned after real use surfaced two problems with the first
        version**, which asked "Save as File?" as a fourth dialog button
        right at Stop, alongside the existing Health save/discard choice.
        First, reported directly and bluntly: deciding whether to keep a
        recording is exactly the kind of decision nobody wants to make
        mid-workout, heart rate still up, on top of *already* having to
        decide about Health. Second, and separately: a workout started
        from the Watch never showed that dialog – or any dialog – on the
        phone at all once stopped (`isWatchCompanionWorkout`'s own
        `.onReceive(session.$pendingSummary)` resets silently, by design,
        so the rider isn't also asked "Save to Health?" for a workout the
        Watch's own `HKWorkoutSession` is already saving on its own),
        which meant "Save as File" never even had a chance to appear
        there – a first attempt at fixing *that* specifically added a
        second, Watch-only "Save this recorded workout as a file?" prompt,
        which turned out not to be the actual problem being reported (the
        workout in question was started from the phone) and, in
        hindsight, was patching around the wrong root cause anyway.
        **Final design**: no decision at Stop at all. `WorkoutRecord`
        gained a `recordedProgram` field, and `reset()` now saves whatever
        `recordedProgramForCurrentWorkout()` returns into it
        unconditionally, exactly like every other part of a finished
        workout – regardless of the Health choice, and regardless of
        whether the workout was started from the phone or the Watch, so
        the whole "which path skips the dialog" question stops mattering.
        `WorkoutHistoryDetailView` gained its own conditional "Save as
        File" section instead (`ShareLink` to a temp file, mirroring the
        existing "Export as .tcx" section right below it exactly) –
        exporting/repeating a good freeride is now something decided later,
        calmly, whenever that specific workout is revisited in Workout
        History, not forced into the moment it just ended.
- [x] **Per-device configurable live-data row, for both treadmill and
      bike** – which values a workout screen shows during a session, and
      in what order, is now set per device in `TrainerDeviceSettingsView`'s
      new "Live Data Shown" section. Started treadmill-only; extended to
      bikes too once it became clear the old global "Speed Display"
      Settings toggle (km/h/pace/kcal-instead-of-speed, cycling only) had
      become the odd one out – a single app-wide setting doing a smaller
      version of what every device now does for itself, per-device and
      per-tile rather than one 3-way switch. Removed outright rather than
      kept alongside the new system: `SpeedDisplayUnit`, its `@AppStorage`
      key, the Settings picker, and `WorkoutSession.liveActiveEnergyKcal`
      (the live kcal reading that setting's "Off" position used to free a
      slot for – computed nowhere else, so it went with it; `EnergyEstimator
      .cyclingActiveEnergyKcal` itself stays, still used for the *final*
      saved-workout calorie total).
      - `LiveMetricKind` covers both machine kinds' tiles in one enum
        (rather than two, since a specific device is permanently fixed to
        one kind or the other anyway) – shared (`.speedKmh`, `.heartRate`,
        `.heartRateAverage`, `.distance`), treadmill-only (`.pace`,
        `.heartRateMax`, `.elevationGain`), and bike-only
        (`.speedKmhAverage`, `.power`, `.powerAverage`, `.cadence`,
        `.cadenceAverage`) – plus a `compatibleMachineKinds` set per case
        so each device's own picker only ever offers what actually applies
        to it (no risk of a bike ending up with `.pace`, or a treadmill
        with `.power`).
      - `TrainerDeviceSettings.liveMetrics: [LiveMetricKind]?` – one
        *ordered subset*, not an on/off flag per case, so a kind missing
        from the array simply isn't shown rather than needing its own
        explicit toggle. `nil` until customized, falling back to
        `effectiveLiveMetrics(for:)`'s own machine-kind-appropriate
        default (treadmill: Speed, Heart Rate, Distance; bike: Power,
        Speed, Heart Rate) – roughly what each machine kind's old fixed
        row already showed, so the first time this screen opens for a
        given device isn't an empty row.
      - `TrainerDeviceSettingsView` renders it as a reorderable, deletable
        `List` (`.onMove`/`.onDelete`, gated behind a new `EditButton()` –
        SwiftUI has no per-`Section` `EditMode`, so it covers the whole
        `Form`, harmlessly, for the Start Countdown/Incline Response text
        fields above it on a treadmill too), plus an "Add Live Data" `Menu`
        listing whichever compatible `LiveMetricKind` cases aren't shown
        yet – one shared `liveMetricsSection`, used from both the
        `.treadmill` and `.bike` cases, rather than duplicating this twice.
      - `ControlView.metricsRow` is now a single implementation for both
        machine kinds (replacing what used to be two separate fixed rows),
        built entirely from `TrainerDeviceSettingsStore.load(for:)
        .effectiveLiveMetrics(for: connection.machineKind)` (same "read at
        the point of use, not cached" pattern `startCountdownSeconds`
        already uses for this same per-device store) – empty for
        `.unknown`, which realistically only lasts a moment right after
        connecting anyway. The heart-rate tile still occupies its
        configured slot even with no strap connected (shows "–") rather
        than disappearing, since the whole point of a user-chosen, fixed
        tile order is that it doesn't reflow around what happens to be
        connected at the moment.
      - `.heartRateAverage`/`.heartRateMax`/`.speedKmhAverage`/
        `.powerAverage`/`.cadenceAverage` all read straight off the
        relevant `LiveStat`'s own `.average`/`.maxValue` – the same
        running min/average/max accumulator every tile's existing
        tap-to-reveal summary already uses, just surfaced as their own
        permanent tiles instead of needing a tap. Tracks *this* workout so
        far, not the rider's own configured Max Heart Rate from Settings –
        called out explicitly in the section's own `InfoButton`, since the
        two are easy to conflate.
      - New `TrainerMetrics.elevationGainMeters`, finally parsing Treadmill
        Data's "Positive Elevation Gain" field (previously skipped
        outright, same as Inclination still is). Deliberately *not*
        estimated from incline × distance when a treadmill doesn't report
        it – there's no live *actual* incline reading to integrate from in
        the first place (see `TrainerMetrics`'s own note on why
        Inclination itself is still unread), so a self-computed number
        would be a guess dressed up as a measurement; shows "–" instead,
        same "no accurate figure means no invented one" rule this app
        applies everywhere energy/effort gets estimated.
- [x] **Resting Heart Rate now kept in sync with Apple Health on every
      launch**, via a new `DeviceListView.refreshRestingHeartRateBPMFromHealth()`
      called from that screen's own `.onAppear` (the app's actual root
      screen, so this fires on every real launch, plus harmlessly again on
      returning to it e.g. after a disconnect). Reuses the existing
      `HealthKitManager.fetchHeartRateProfile` outright rather than adding
      a new, narrower HealthKit read method – only `profile.restingBPM` is
      actually used here, `maxBPM` is simply ignored.
      Deliberately a different policy from `SettingsView`'s own, already-
      existing `prefillHeartRateProfileIfNeeded()`: that one only ever
      fills an *unset* (`== 0`) field, once, the first time Settings
      happens to be opened, for *both* Max and Resting Heart Rate. This
      new path *overwrites* Resting Heart Rate unconditionally, every
      time, deliberately narrowed to that one field – asked for
      specifically because resting heart rate genuinely drifts as fitness
      changes over weeks/months, and on a phone paired with a Watch is
      itself a Health-measured value the rider almost certainly isn't
      hand-editing, unlike Max Heart Rate (left on its existing one-time-
      prefill policy on purpose – that one stays rider-owned, expected to
      be overridden with a real test result rather than kept in lockstep
      with whatever Health happens to say). A no-op whenever Health has no
      reading on record, isn't available, or access is denied – doesn't
      fall back to `SettingsView.restingHeartRateFallbackBPM` the way that
      screen's own first-time setup does, since there's already a
      perfectly good existing value worth just leaving alone in that case.
- [x] **Fixed the +/- step buttons genuinely running away after release**
      (reported as still happening despite the existing `maxRepeatDuration`
      hard cap) – root cause was `RepeatingStepButton` tracking "is this
      still held" as a plain `@State` toggled from `DragGesture`'s
      `.onChanged`/`.onEnded`, which has no `.onCancel` at all: if the
      system ever *cancels* the gesture instead of ending it normally (the
      enclosing `ScrollView` claiming the touch mid-press for its own
      scroll gesture is the likely trigger – this sits right next to the
      once-a-second workout updates that keep re-rendering the view while
      held), `.onEnded` simply never fires, and a plain `@State` only ever
      toggled there stays stuck `true` forever – exactly what the existing
      hard cap was papering over rather than fixing. Switched to
      `@GestureState` (via `.updating(...)` instead of `.onChanged`/
      `.onEnded`) – SwiftUI resets a `@GestureState` property back to its
      initial value the moment the gesture becomes inactive for *any*
      reason, cancellation included, so `.onChange(of:)` now reliably sees
      the press end either way. `maxRepeatDuration`'s hard cap stays in
      place regardless, purely as a defensive backstop.
- [x] **Speed & Incline's own speed step lowered from 0.5 km/h to 0.1
      km/h** – reported as too coarse specifically there: 0.5 km/h is a
      proportionally much bigger jump on foot than the same number is by
      bike (e.g. ~9 % of a brisk 5.5 km/h walk per tap), and pace-based
      training in particular calls for finer adjustments. Incline's own
      step, and every other mode's, are unaffected.
- [x] **Hardened `ShorthandWorkoutParser` and added its treadmill
      counterpart, `TreadmillShorthandParser`** – the deterministic,
      offline alternative settled on after `feature/ai-workout-generator`
      (Apple's on-device Foundation Models framework, see that branch and
      its own commit history) turned out simultaneously unreliable for
      anything beyond a single stated number *and* out of proportion for
      what this app actually needs: a classical, testable parser handles
      the same "type a workout in plain-ish text" job without a model,
      a context window, or an iOS 26 requirement.
    - New shared file `ShorthandNotation.swift`: `consumePrefixedValue(_:units:)`
      matches `NUMBER UNIT` at the start of a string – with or without a
      space, and with `,` or `.` as the decimal separator – trying every
      candidate unit longest-first and rejecting a match that's actually
      just a prefix of some longer, unlisted word (so "minutes" is never
      mistaken for "minute" plus a dangling "s"). Both parsers' own
      tokenizing is built on this now, rather than the previous exact
      single-space-delimited split, which is what "Fehlbedienung" (a rider
      reported the current one working "reasonably" but too easy to get
      wrong) actually meant in practice: "10min60%FTP" (no space) or
      "3,5min 200W" (German decimal comma) used to be hard parse failures
      despite being perfectly unambiguous asks. `splitTopLevel(_:separator:)`
      (top-level comma-splitting, shared between both parsers) also learned
      not to treat a `,` between two digits as a step separator, for the
      same decimal-comma reason.
    - Both parsers also gained a parenthesis-free single-step repeat –
      "4x5min 105%FTP" / "8x400m 12km/h", the way this is actually phrased
      in practice – alongside the original "Nx(...)" multi-step form,
      which still works unchanged.
    - `TreadmillShorthandParser` (new): `step := length speed incline?` –
      `length` is either a duration (min/sec/h, plus German synonyms) or a
      *distance* (m/km, plus the imperial units asked for specifically:
      mi/yd/ft), converted to the block's actual duration via whichever
      `speed` follows it in the same step (`durationSeconds = distanceMeters
      × 3.6 / speedKmh`) – unambiguous because, unlike a bike step, a
      treadmill step never ramps between two different speeds
      (`TreadmillWorkoutSegment` itself only ever holds one flat speed for
      its whole duration). `speed` itself accepts `km/h`/`kmh`/`kph` or
      `mph`/`mi/h`, always converted to km/h at parse time – this app's one
      canonical unit throughout, same as every file format it reads.
      `incline` is optional, defaulting to flat (`0%`) when omitted. Wired
      into `CreateWorkoutView` (now takes `machineKind`, and both a
      `WorkoutProgram`/`TreadmillWorkoutProgram` save closure – only the
      one the chosen grammar can actually produce ever fires) and
      `ControlView`'s "Create" button, gated the same way `.zwo` loading
      already is (`supportsSpeedTarget || supportsInclinationTarget`)
      rather than the bike-only `supportsPowerTarget` it was stuck behind
      before.
    - Verified with a standalone `swiftc`-compiled test harness (no Xcode
      project needed for the parser logic itself) covering both parsers:
      the original grammar's examples still parse identically, plus the
      no-space/decimal-comma/German-synonym/parens-free-repeat cases, plus
      `TreadmillShorthandParser`'s own distance-to-duration conversion
      (400 m, 0.5 mi, 100 ft, 40 yd, all cross-checked by hand against the
      expected seconds) and every error path. Also smoke-tested the full
      UI wiring end-to-end in the Simulator (`CreateWorkoutView` for
      treadmill, via a temporary `#if DEBUG` entry point removed again
      afterward) – live preview updates correctly while typing, Save
      round-trips through to the machine-kind-appropriate closure.
- [x] **Ported the same shorthand notation to `docs/builder.html`
      ("Interval Sketch")** – the rider asked for it directly after the
      app-side hardening above, correctly pointing out the same "type
      instead of drag" convenience, and the same missing-space/decimal-
      comma "Fehlbedienung", would apply there too. No shared code between
      Swift and a static HTML page, so this is a hand-ported JavaScript
      twin of `ShorthandNotation`/`ShorthandWorkoutParser`/
      `TreadmillShorthandParser` – same grammar, same tolerance rules –
      rather than an attempt at literally sharing the implementation.
      Hooks into the *existing* `.erg`/`.mrc`/`.zwo` preview textarea
      (already editable, already synced back to the chart on `input` –
      see `handlePreviewEdit`) instead of adding a separate input field:
      `looksLikeWorkoutFile(text)` checks for `[COURSE DATA]`/
      `<workout_file>`, and only falls through to the new shorthand parser
      when neither is present. The parsed result is fed through the exact
      same bin-resampling the file importers already use
      (`resampleToBins` for bike, the same `segmentAt`-style lookup
      `applyZwoText` already had for treadmill) rather than a second
      "shorthand → chart" path of its own. Verified two ways: a Node.js
      harness running the extracted parsing functions directly against
      the identical cases used for the Swift version's own test (every
      result – including the distance/imperial-unit conversions – matched
      exactly), and a live browser check of the actual textarea → chart
      wiring for both machine kinds plus an error case.
- [x] **Two more bike shorthand tolerances, reported against a real
      example** (`10' 60%FTP, 4x(5min 105% FTP, 3min 50% FTP), 10min
      55% FTP`) – ported to both `ShorthandWorkoutParser.swift` and
      `docs/builder.html`'s JS twin identically:
    - `'` (a bare prime) as a minutes alias, so `10'` means the same as
      `10min`. Bike-only, deliberately not added to
      `TreadmillShorthandParser`'s own duration units – there `'` would be
      genuinely ambiguous with feet (the same prime-for-minutes-or-feet
      overload this notation always carries), a collision a bike step
      never has to worry about since it has no distance unit at all.
    - A space before the target's own unit ("105% FTP", "200 W") – target
      matching now strips internal whitespace before comparing suffixes,
      rather than requiring the value and its unit glued together with no
      space at all.
    - Verified against the exact reported example, both in the standalone
      Swift test harness and the Node.js one for the web tool – both
      produce the identical 20-breakpoint, 3120s (52 min) result the
      original (space/prime-free) phrasing of the same workout already
      did, confirmed live in the browser too (chart syncs, reads 52:00).
- [x] **`"` (a bare double prime) as a seconds alias** – `90"` means the
      same as `90sec` – the other half of the same prime/double-prime
      notation `'` already covers for minutes. Unlike `'`, added to
      *both* `ShorthandWorkoutParser` and `TreadmillShorthandParser` (and
      both's JS twins in `docs/builder.html`) – `"` 's usual other
      meaning, inches, was never a supported distance unit here in the
      first place, so there's nothing for it to collide with the way `'`
      would with feet. Verified in both languages, plain and nested
      inside a repeat group, on both machine kinds.
- [x] **`docs/builder.html`'s Power lane can now draw genuine linear
      ramps within one bin**, not just flat blocks – matching what
      `.erg`/`.mrc` already support natively (a bike shorthand ramp step,
      "20min 100W->300W", could already produce one; the chart itself
      couldn't draw or edit one until now). Bike/Power only –
      `TreadmillWorkoutSegment` has no ramp concept at all (every real
      `.zwo` block is a single flat Pace/Incline for its whole duration),
      so Speed/Incline are untouched.
    - Interaction, exactly as the rider described it: hold Shift and
      hover near a bin's own left or right edge to reveal a small handle
      sitting at that endpoint's current value; grab and drag it
      vertically to move *only* that one endpoint. A plain paint (no
      Shift, or Shift away from an edge) still sets both ends equal, so
      painting over a ramped bin remains how to flatten it – no separate
      reset control needed. Two adjacent bins' edges sit at the same x
      but are independent values; which one a Shift-drag grabs falls out
      for free from which bin `Math.floor` already resolves the pointer
      to, needing no extra disambiguation.
    - Data model: `state.power[i]` changed from a plain number to
      `{start, end}` (`start === end` for a flat bin, same as every
      existing bin). Touched every place that assumed a plain number:
      rendering (`renderLane` now reads `.start`/`.end` for its step-path,
      which draws a slope across a ramped bin for free, no extra branch),
      `.erg`/`.mrc` export (now writes the real start/end pair instead of
      one repeated value – a bin that's flat still round-trips
      identically), `.zwo` export (can't represent a ramp at all, so a
      ramped bin is exported as its own single-bin block at its start/end
      average, deliberately never merged with a neighbor even if that
      neighbor's own average happens to match), file/shorthand import (a
      new `resampleToBinsRamped` reads the source curve at each bin's own
      start/end instant instead of its midpoint, so an imported ramp –
      from a real `.erg` file or a bike shorthand "->" step – survives
      as an actual ramp instead of collapsing to one flat value),
      bin-count changes, and old-localStorage migration (a returning
      rider's plain-number `power` array is normalized to `{start, end}`
      on load).
    - Found and fixed a real bug while testing this with synthetic
      pointer events: `hit.setPointerCapture(evt.pointerId)` in
      `pointerdown` had no try/catch, unlike every `releasePointerCapture`
      call elsewhere in this file – it can throw ("no active pointer with
      the given id"), which silently aborted the *entire* gesture,
      painting included, not just the new ramp handles. Wrapped it the
      same defensive way release already was.
    - Verified with synthetic `PointerEvent`s dispatched directly at
      computed bin-edge coordinates (Shift+drag a start edge, an end
      edge, and a plain flatten-paint over a ramped bin), reading the
      result back from the regenerated `.erg`/`.zwo` preview text each
      time – confirmed a ramped bin's two ends move independently, a
      plain paint flattens it again, `.erg` output shows the genuine
      ramp, and `.zwo` isolates the ramped bin into its own block rather
      than merging it. Treadmill mode re-checked afterward, unaffected.
- [x] **A ⋮ Settings popover in `docs/builder.html`'s toolbar, with its
      first setting: "Snap to start/end"** – while Shift-dragging a ramp
      handle, the dragged endpoint snaps exactly onto the adjacent bin's
      own end/start once it comes within `SNAP_HIT_PX` (6px) of it, so
      building a smooth multi-bin ramp (each bin's end meeting the next
      one's start with no jump) doesn't need pixel-perfect placement by
      hand. On by default, toggle-able (persisted in `state.snapEnabled`
      the same way `speedStep` already is), and – the rider's own
      addition to the idea – overridable per-drag by holding Ctrl (⌃ on
      Mac; `evt.ctrlKey` reads the same physical key on both without
      needing to branch on platform, unlike ⌘/Meta) when a genuinely
      close-but-different value is actually wanted. The popover itself
      (`#settings-menu-btn`/`#settings-popover`, click-outside and Escape
      both dismiss it) is built to hold more settings rows later, not
      just this one. Verified with the same synthetic-`PointerEvent`
      technique as the ramp handles themselves: a near-neighbor drag
      snaps, the identical drag with `ctrlKey: true` doesn't, and
      unchecking the popover's own toggle turns snapping off entirely –
      all three read back from the regenerated `.erg` preview text.
- [x] **Snap to start/end now also applies to a plain (non-Shift) paint
      drag**, not just the ramp-handle gesture above – reported right
      after, extending the same idea to a whole flat bin: painting a bin
      to a value close to its left neighbor's own `end` or right
      neighbor's own `start` snaps onto whichever of the two it's closer
      to, within the same `SNAP_HIT_PX`. Only the bin actually under the
      pointer snaps this way – the intermediate bins a fast multi-bin
      drag smears across stay plain linear interpolation, not each
      independently pulled toward a neighbor. Same Ctrl override and
      popover toggle as the ramp-handle case, sharing the same
      `state.snapEnabled` flag – one setting governs both gestures.
      Verified the same way: a close value snaps, Ctrl held keeps it
      exact, and a value far from either neighbor is left untouched.
- [x] **Found and fixed a real reload-loses-your-edits bug in
      `docs/builder.html`, and added Undo/Redo** – reported together
      since the fix's own verification needed something to actually
      undo/redo against.
    - The bug: `STORAGE_KEY` used to be declared down in the "persistence"
      section, textually *after* `loadStateFromStorage()` is first called
      a few lines into the file (restoring `state` from whatever's saved).
      `var` only hoists the *declaration*, not the assignment – so at that
      first call, `STORAGE_KEY` was still `undefined`, and
      `storage.getItem(undefined)` silently reads back the wrong key
      ("undefined", coerced to a string) and finds nothing there, every
      single time, regardless of whether a real save had just happened
      moments before. This is *not* something introduced this session –
      it's been there since this file's own persistence code was first
      written, just never actually exercised in a way that surfaced it
      (this session's own testing, both earlier and today, mostly used
      the sandboxed preview pane, where `localStorage` throws outright
      just being touched – a *different* failure this file's `try/catch`
      already handled fine, which is exactly why this second, more subtle
      bug went unnoticed until tested over a real local HTTP server –
      `python3 -m http.server`, not `file://` or the sandboxed preview –
      where `localStorage` genuinely works and the wrong-key read could
      actually be observed). Fixed by moving `STORAGE_KEY`'s declaration
      to the very top of the file, before anything can possibly read it
      too early. Also hardened the storage layer itself while in there:
      `pickStorage()` now probes `localStorage` first and falls back to
      `sessionStorage` (survives a reload, cleared when the tab closes –
      still exactly what "restore my in-progress edits" needs) if
      `localStorage` itself throws merely being touched, rather than only
      catching failures from individual `get`/`setItem` calls.
    - Undo/Redo: a proper history stack (`undoStack`/`redoStack`, capped
      at 100 entries), scoped to the *workout itself*
      (`mode`/`binSeconds`/`bins`/`warmupBins`/`cooldownBins`/`power`/
      `speed`/`incline`) – `ftp`/`speedStep`/`snapEnabled` (tool
      preferences/rider data, not drawn content) stay out. `pushUndo()`
      is called once at the *start* of each discrete action (a whole
      paint/ramp/boundary-handle drag, one stepper click, one mode/
      interval-length switch, one shorthand/file apply) – critically,
      *not* inside `setWarmup`/`setCooldown` themselves, which (unlike
      every other mutator) are also called on every `pointermove` of a
      boundary-handle drag; pushing there would have flooded the history
      with one entry per pixel dragged instead of one per gesture, found
      and avoided before it ever shipped. Undo/Redo buttons in the
      toolbar (disabled when their stack is empty) plus Ctrl+Z/Ctrl+
      Shift+Z/Ctrl+Y (⌘ variants on Mac – `metaKey`, unlike the snap-
      override gesture's deliberately-platform-identical `ctrlKey`, since
      undo/redo genuinely differs by platform convention), skipped
      entirely while an `INPUT`/`TEXTAREA` has focus so a field's own
      native text-undo isn't hijacked. History itself is session-only –
      resets on reload, same as most editors' own undo history – only the
      *current* state persists across one, per the fix above.
    - Verification took real work: synthetic `PointerEvent`s plus
      `console.log` debugging kept showing confusing, seemingly-wrong
      results at first, traced back to two artifacts of the test setup
      itself rather than real bugs – `read_console_messages` turned out
      to return logs accumulated across every earlier navigation in the
      session, not just the current page load (misread as stray
      duplicate pushes), and a `localStorage.clear()` called *after*
      navigating to a fresh load (rather than before) left an
      already-fixed reload correctly restoring a previous test's own
      leftover edit (misread as undo doing nothing). Switching to a
      `window.__debug*`-hook style of introspection (removed again once
      done) instead of console logging, and clearing storage *before*
      each fresh navigation, resolved both false leads – the underlying
      undo/redo logic itself turned out correct the whole time. Final,
      clean run over a real `http://127.0.0.1` server (not the sandboxed
      preview, not `file://`, both of which restrict storage in ways that
      would have hidden the original bug entirely): paint, paint again,
      undo twice, redo twice – values and button-disabled states correct
      at every step; the reload fix confirmed by painting a value,
      reloading, and reading it back unchanged; the keyboard shortcut and
      its text-field exception both confirmed directly.
- [x] **Investigated a real crash from a live walking workout**, reported
      with a suspicion it was tied to a treadmill segment transition
      involving a negative (device-unsupported) incline value. That turned
      out to be a dead end, but only after real digging: the app's own
      MetricKit diagnostic (`DiagnosticsReporter`, see its entry above) only
      carries binary-UUID/offset pairs, not symbol names, and this Mac had
      no dSYM matching the crashed build anywhere (`~/Library/Developer/
      Xcode/Archives` empty, current DerivedData build a different UUID
      entirely, no Spotlight hit for the UUID either) – so the first, more
      thorough pass through the incline-clamping code in `WorkoutSession
      .sendCurrentWorkoutTarget(for:)` and `TrainerConnection
      .setTargetInclination(percent:)` (confirming both already clamp to
      `inclinationRangePercent`, and that clamp already predates this crash
      by five days) was done *blind*, without being able to prove it was
      even looking at the right function. Two full device `.ips` crash logs
      later (fetched via Xcode's Devices and Simulators → View Device Logs,
      the reliable way to get one Xcode can actually symbolicate) resolved
      it properly – but the first one pasted turned out to be a *different,
      already-fixed* crash from six days earlier (a `Dictionary
      (uniqueKeysWithValues:)` duplicate-key fatal error in
      `mergedWorkoutSamples()`, fixed the same evening it happened, see the
      clock-drift entry above – confirmed via `git log -S` against its own
      `uniquingKeysWith:` fix landing 52 minutes after that log's own
      timestamp). The real one, matching the original MetricKit report's
      own binary UUID and faulting address exactly, was something else
      entirely: `EXC_BAD_ACCESS`/`SIGSEGV`, "possible pointer authentication
      failure", with `objc_msgSend` called from `__NSThreadPerformPerform` –
      CoreBluetooth's own internal mechanism for delivering a delegate
      callback to the main thread after the fact, not anything this app
      schedules or can cancel directly. That's the same class of crash
      `BluetoothManager.clearConnection()` was already hardened against on
      2026-09-01 (see its own doc comment) – but that fix only runs on the
      one path that happens to route through it (navigating back out of
      `ControlView`), and this crash happened mid-workout, no navigation
      involved. Found one genuine, still-open way `TrainerConnection`
      could be dropped without ever reaching that cleanup: `UnchainApp`'s
      `DeviceListView().id(languageOverride)` discards and rebuilds the
      *entire* subtree – `BluetoothManager`, `TrainerConnection`, the
      `CBCentralManager` itself – on any language-setting change, bypassing
      `clearConnection()`'s careful disconnect-before-release order
      completely; not provably what happened here (nothing suggests the
      language setting changed mid-walk), but a real gap regardless, and a
      sign the original fix's scope (one specific navigation path) was
      never actually the full guarantee its own doc comment implied.
      Neither `TrainerConnection` nor `HeartRateConnection` had a `deinit`
      at all – added one to each, calling the same
      `central?.cancelPeripheralConnection(peripheral)` `disconnect()`
      already does, as the one cleanup path guaranteed to run no matter
      *which* way the object stops being referenced, present or future,
      rather than only the ones already known about today. Can't claim
      certainty this was *the* trigger – the crashed thread's own stack is
      100% system frames (run loop → source0 → perform → objc_msgSend),
      no app code on it at all to point at a specific call site – but it's
      a real, previously-unguarded gap in the same already-diagnosed class
      of bug, fixed the same defensive way the first instance of it was.
      Followed up with a deliberate sweep of the rest of the app for the
      same *family* of bug – something async/system-framework-mediated
      outliving, or acting on stale state from, the app-side object that
      set it up – not just the one CoreBluetooth-specific shape above.
      Found and fixed one more, real one: `WatchConnectivityManager.shared`
      (a singleton, living for the whole process) holds `onStartRequested`/
      `onStopRequested` closures that `ControlView.configureWatchCompanion()`
      sets on every `.onAppear` – but nothing cleared them on the way back
      out. Since those closures capture `connection`/`session` via this
      struct's own `self` (`@ObservedObject`/`@StateObject`, both real
      class references), leaving `ControlView` used to leave the singleton
      holding a strong reference to that specific `TrainerConnection`/
      `WorkoutSession` pair indefinitely – silently defeating the very
      `deinit`-based cleanup just added above (it never fires while
      something else still holds a strong reference) until the next
      connection's own `configureWatchCompanion()` call happened to
      overwrite the closures, and, worse, leaving a stale Watch "start"/
      "stop" request able to act on a connection nothing on the phone
      still considers current. Fixed with a matching `.onDisappear` that
      clears both closures – everything else checked (`WorkoutSession`'s
      own `Timer`/Combine `metricsCancellable`, `HealthKitManager`'s
      completion-closure calls, `WatchWorkoutManager`'s watchOS-side
      `HKWorkoutSession`/`HKLiveWorkoutBuilder`/`WCSession` handling, the
      long-press-repeat `Timer` behind `ControlView`'s own +/- stepper
      buttons) already followed this same discipline correctly –
      consistent `[weak self]` where a class could actually outlive its
      own callback, cancellation on teardown, no stored closures on a
      long-lived singleton left unguarded anywhere else. `git grep`-level
      sweep, not exhaustive proof nothing else remains, but a real,
      deliberate pass, not just the one spot the crash happened to point at.
- [x] **Pace now reads `6'00"` instead of `6:00`** – requested directly:
      a bare-colon clock reading looks like a pace either way, but this app
      already has its own meaning for `'`/`"` (minutes/seconds – see
      `ShorthandNotation`'s prime/double-prime notation, used throughout
      `ShorthandWorkoutParser`/`TreadmillShorthandParser`), so keeping the
      live pace tile in bare-colon notation was the one place still
      inconsistent with it. `paceString(fromSpeedKmh:)` in `ControlView.swift`
      is the only formatter that ever produced this – confirmed via a repo-
      wide search, `formattedDuration(_:)` in `WorkoutHistoryView.swift`
      (overall workout duration, h:mm:ss) is a different, unrelated
      formatter and stays as-is.
- [x] **The `m ↑` elevation-gain tile now falls back to a self-computed
      estimate** for a treadmill that doesn't report FTMS's own "Positive
      Elevation Gain" field – previously just "–" forever on any such
      device, a call I'd made and explained in `TrainerMetrics
      .elevationGainMeters`'s own doc comment, on the reasoning that this
      app never reads the treadmill's own live *actual* inclination back
      (the Treadmill Data characteristic's Inclination field was, and
      still is, parsed-past/unused), so a self-computed number would be a
      guess dressed up as a measurement. Revisited, and disagreed with,
      directly: this app already knows the incline it *commanded* the
      treadmill to hold, continuously, for either kind of treadmill
      session – `WorkoutSession.lastSentTreadmillInclinePercent` for a
      `.zwo`-driven one, `recordedTreadmillInclinePercent` for a manual
      `.speedIncline` one (exactly one of the two is ever non-`nil` in a
      given session, so no separate "which mode" branch is needed) – and
      combined with the genuinely live, real `instantaneousSpeedKmh`
      already integrated into `distanceMeters` every tick, that's enough
      for a reasonably precise running total, physical incline-motor lag
      aside. New `WorkoutSession.estimatedElevationGainMeters`, integrated
      in `refreshWorkoutState` the same way `distanceMeters` already is –
      `distance × commandedInclinePercent / 100` per tick, only while the
      commanded incline is positive (flat/descending contributes nothing,
      same "gained never means descended" convention the real FTMS field
      already follows) – and only for a treadmill at all, a bike's
      `setSimulationGrade(percent:)` being a resistance simulation with
      nothing physical to climb. `ControlView`'s tile still prefers the
      device's own real reading first; the estimate only fills in when
      that's genuinely absent, and – matching `.distance`'s own tile right
      above it, which has never shown "–" either – shows a plain running
      number throughout, not a fallback special-cased only once a workout
      is actually under way.
- [x] **Tightened the elevation-gain estimate above with the treadmill's own
      per-degree incline travel time** – it was integrating the flatly-
      commanded target incline the instant a `.treadmillProgram` transition
      sent it, same as `sendCurrentWorkoutTarget(for:)`'s own speed ramp
      used to before *that* was added (see "Fix treadmill speed ramp taking
      too long…"). New `WorkoutSession.estimatedPhysicalInclinePercent`
      models the incline as still catching up during that same window,
      reusing the identical ramp timing (`treadmillSpeedRampStartSeconds`/
      `treadmillSpeedRampDurationSeconds`, itself already computed from
      `TrainerDeviceSettingsStore`'s `effectiveInclineChangeSecondsPerDegree`)
      the speed ramp already paces itself against – never fed back into
      what's actually *sent*, which still goes out as one flat target
      immediately, only into this session's own estimate of where the belt
      physically is. A manual `.speedIncline` session mirrors its own
      commanded incline immediately instead, with no ramp modeling – a
      rider's own `+`/`-` tap has no comparable safety-ramp reason to model
      a lag for, and each step is small enough for the flat-instant
      assumption to barely matter there.
- [x] **A loaded workout with illegal targets now gets quietly corrected in
      place, not just warned about** – `warnIfOutOfRange(_:)` (both the
      `.power`-kind `WorkoutProgram` overload and the `TreadmillWorkoutProgram`
      one) still shows the exact same alert it always has, but now also
      rewrites the loaded program's own out-of-range breakpoints/segments
      to whatever this trainer's real range clamps them to, via two new
      `WorkoutSession` methods (`clampActiveProgramPowerTargets(to:)`,
      `clampActiveTreadmillProgram(speedRange:inclineRange:)`). Requested
      directly: `setTargetPower`/`setTargetSpeed`/`setTargetInclination`
      already clamped everything actually *sent* regardless, but
      `WorkoutProgramChart` and `TreadmillProgramSegmentList`'s table (and
      its own current-segment row – a treadmill program's only "what's it
      doing right now" indicator, there's no chart for that workout kind)
      kept showing the file's original, illegal figures for the rest of
      the workout, quietly disagreeing with the live numbers once playback
      actually reached one of them. Both new methods are deliberately
      *not* gated on `state == .idle` the way `loadProgram(_:)`/
      `loadTreadmillProgram(_:)` themselves are – they only ever rewrite
      the workout's own stored values, never touch playback position or
      any other session state, so it's exactly as safe to call mid-workout
      (the moment a range answer actually arrives late over BLE, one of
      the two call sites) as before Start. The treadmill version clamps
      speed/incline independently, passing `nil` for whichever range
      hasn't actually been reported by this trainer yet – same
      independence `warnIfOutOfRange(_:)`'s own two `…OutOfRange` checks
      already had.
- [x] **Closed the actual race `TrainerConnection`/`HeartRateConnection`'s
      own `deinit`-based cleanup only narrowed** – pointed out directly,
      and correct: `deinit` runs once the *last* strong reference is
      already gone, too late to protect against a callback CoreBluetooth
      had already queued for its own internal main-thread-deferred
      delivery *before* that moment – nothing app-side can retroactively
      cancel an already-scheduled one, and an object can't re-retain
      itself from inside its own `deinit` to survive longer either way.
      New `BLEDisconnectGracePeriod` (own file, shared by both types) is
      the actual fix: called from `disconnect()` instead – while a valid
      strong reference to hand off still exists, before every real call
      site immediately drops its own – it keeps the object alive for a
      short, self-expiring grace period past that point, so a straggler
      callback that was already queued lands on real (if by then inert)
      memory instead of freed/reused memory once it does fire. Doesn't
      stop the callback from firing – can't – just changes what it lands
      on: the actual difference between this crash and a silent no-op.
      `disconnect()` on both types also now nils `peripheral.delegate`
      itself as an extra, best-effort signal alongside the existing
      `cancelPeripheralConnection` call. `deinit`'s own `cancelPeripheralConnection`
      call stays – now explicitly documented as the narrower catch-all for
      whatever path doesn't go through `disconnect()` first, rather than
      the primary defense it read as before this.
- [x] **Closed the actual capture behind the Watch-companion closures too,
      not just the `.onDisappear` symptom of it** – pointed out directly,
      and correct: `ControlView.configureWatchCompanion()`'s two closures
      captured `self` (hence `connection`, transitively, via this struct's
      own `@ObservedObject`) to reach `connection.state`/`connection
      .machineKind` and several of this view's own `@State` properties
      (`isWatchCompanionWorkout`, `treadmillActivityType`,
      `pendingWatchStartCompletion`, `isChoosingTreadmillActivity`) –
      `WatchConnectivityManager.shared` being a singleton that outlives
      any one `ControlView` meant that capture, not just the closures
      existing at all, was the actual problem. `.onDisappear` nilling them
      back out (see the entry three above this one) covers every path that
      reaches it, but is still an event-driven convention a future code
      change could silently bypass, not a guarantee – "only partially
      fixed", the same critique the `deinit` narrowing above got, and just
      as correct here.
      Real fix: split `onStartRequested` into two stages, mirroring
      `pendingSummary`'s own already-established "session publishes a
      pending decision, the view reacts to it with the UI-state access
      only it has" pattern. The closure actually stored on the singleton
      now captures `[weak session]` and *nothing else* – a fast
      `session.state == .idle` rejection, or handing the request off to a
      new `WorkoutSession.watchStartRequestCompletion` (`@Published`, like
      `pendingSummary`) – `connection` and every `@State` property above
      are never touched from inside it at all. A new
      `.onReceive(session.$watchStartRequestCompletion)` on `ControlView`
      (same `.onReceive`-not-`.onChange` reasoning `pendingSummary` already
      has: a closure isn't `Equatable`) calls the new
      `handleWatchStartRequest(completion:)`, which picks up exactly where
      the old inline logic left off – full, always-*current* `self` access,
      since it runs live in the view rather than from a stored closure.
      `onStopRequested` needed nothing beyond `session` in the first place
      (`session?.stop()`) and is now `[weak session]` too. `.onDisappear`'s
      nilling stays, now genuinely defense-in-depth rather than the only
      thing actually closing the gap – with `[weak session]`, a stale
      request now just resolves to a harmless `guard let session` miss
      even if it somehow still fired.
- [x] **Estimated treadmill power** – `.power`/`.powerAverage` were bike-only
      tiles (`LiveMetricKind.compatibleMachineKinds`); now available for a
      treadmill too, same "device's own real reading first, an estimate
      only when that's genuinely absent" fallback shape `estimatedElevationGainMeters`
      already established. Went through two real revisions before landing
      here, each one a direct, reasoned pushback on the last:
      - First cut: a metabolic (VO2-based) estimate, reusing the ACSM
        equation `walkRunActiveEnergyKcal(...)` already had for the
        post-workout calorie figure, this time with its grade term
        actually included. Flagged directly as "a wrong track" – the
        resulting Watt figures ran noticeably higher than a bike's own
        power meter would for a similar felt effort (resting metabolism
        and gross inefficiency both baked into VO2), not a comparable
        number under the same "Watt" label.
      - Second cut: pure physics instead – `EnergyEstimator
        .climbingPowerWatts(weightKg:speedKmh:inclinePercent:)`,
        $P = m \cdot g \cdot v \cdot \frac{\text{incline}}{100}$, the rate
        of work done raising body weight against gravity. No efficiency
        factor, no regression, genuine mechanical watts. Trade-off: `nil`
        on the flat, not `0` – a treadmill belt offers no real external
        resistance to steady-pace walking/running the way a bike's
        wind/rolling resistance does, so there's nothing for this formula
        to measure there. Flagged as a real gap on its own: the app would
        show "–" for the majority of ordinary flat-ground treadmill time.
      - Landed on adding a second formula for exactly that flat stretch
        rather than reworking the first: `EnergyEstimator
        .internalWorkPowerWatts(weightKg:speedKmh:)`, from classic
        gait-energetics literature (Cavagna, Saibene & Margaria; later
        R. McN. Alexander) – the *internal* mechanical work of
        swinging/decelerating the limbs relative to the body's own center
        of mass, roughly 0.3–0.6 J/(kg·m), `0.5` used here as the
        midpoint. Explicitly a rougher, literature-derived coefficient,
        not exact physics like the climbing formula – new `WorkoutSession
        .EstimatedPowerSource` (`.climbing`/`.internalWork`) tracks which
        one produced the current reading, and `ControlView`'s `Watt` tile
        colors an `.internalWork` value red specifically, rather than
        presenting both with the same visual confidence. Deliberately
        left for real-use measurement to judge, not tuned further up
        front: "wie plausibel die Werte bei geringer Steigung sind, werde
        ich empirisch ermitteln."
      Neither formula takes a gender parameter, nor distinguishes walking
      from running – weighed directly for the metabolic attempt (ACSM is
      already weight-normalized and sex-independent) and carried forward
      unchanged since; the internal-work coefficient is really best
      established for running specifically, applying it to walking too
      likely overstates a walker's own internal work somewhat, noted
      in-code as a known simplification rather than silently assumed away.
      New `WorkoutSession.bodyWeightKg` – the one input only `ControlView`
      has – and a new `HealthKitManager.fetchBodyWeightKgForLiveEstimate(completion:)`
      (same `bodyMassReadType`-only authorization scoping as `save()`'s own
      request, see this class's own doc comment for the real bug that
      established why – and, since this is treadmill-triggered only, a
      bike rider is never prompted for a permission this app wouldn't even
      use for their workout). Called from `ControlView`'s `.onAppear`/
      `.onChange(of: connection.machineKind)`, not gated on Start, so
      whatever the answer turns out to be is already resolved long before
      the rider presses it – never something a live tile is left waiting
      on mid-workout. `estimatedPowerWatts` itself is instantaneous, not
      cumulative (recomputed, not integrated, each tick) – its own running
      min/average/max is tracked in a dedicated new `estimatedPowerStats`
      (blending both formulas' own samples together, unlike the instant
      reading's own color-coding – an average spanning both flat and
      inclined stretches has no single confidence level left to flag),
      kept deliberately separate from `powerStats`/`workDoneJoules`/
      `powerHistory`, all three of which mean *real*, device-reported
      mechanical power elsewhere in this app (`WorkoutSummary
      .workDoneKilojoules`'s own doc comment is explicit it's `nil` "for
      machines that don't report power") – folding an estimate into any of
      those would quietly contradict that.
- [x] **Body Weight – new explicit Settings field, refreshed from Health at
      every treadmill Start** – the power estimate above was still missing
      the one input driving its mass term: it fetched once per connection
      (`WorkoutSession.bodyWeightKg`, cached the moment a treadmill
      connected, never asked again) with no way to see or correct it.
      Reported directly as missing. Replaced with a new `SettingsView
      .bodyWeightKgKey` field – a plain, editable `Double`, same "e.g. …"
      placeholder/`InfoButton` shape every other profile number on that
      screen already has (own `zeroAsEmptyText(_: Binding<Double>)`
      overload, tolerant of a German-keyboard decimal comma same as the
      shorthand notation elsewhere) – kept in sync automatically by a new
      `ControlView.refreshBodyWeightKgFromHealth()`, called from
      `startSession()` so it runs on *every* actual Start regardless of
      what triggered it (the plain phone button, the "Walking or running?"
      dialog, a Watch-triggered start – `startSession()` is already the
      one shared chokepoint for all three). Same "overwrite from Health
      every time, but only when Health actually has an answer, never with
      an invented one" reasoning `DeviceListView
      .refreshRestingHeartRateBPMFromHealth()` already established for
      Resting Heart Rate – deliberately reused rather than inventing a
      third pattern, since the two are genuinely the same shape: a
      Health-measured value the rider almost certainly isn't hand-editing
      day to day, refreshed automatically, but still a plain field for the
      cases that reasoning doesn't cover (no scale synced to Health, a
      stale reading). `WorkoutSession.refreshWorkoutState` now reads
      `UserDefaults.standard.double(forKey: SettingsView.bodyWeightKgKey)`
      directly rather than through a stored property – the same
      "fresh from `UserDefaults` at the point of use" pattern
      `estimatedVO2Max(samples:)` already used for Max Heart Rate, so
      `WorkoutSession` doesn't need its own settable `bodyWeightKg`
      property (removed) or any cross-object wiring to stay current with a
      value `ControlView`'s own Settings sheet might change mid-session.
- [x] **Fixed a real gap the entry above left**: Body Weight showed up
      empty the first time Settings was opened – reported directly.
      `ControlView.refreshBodyWeightKgFromHealth()` only ever ran at a
      treadmill workout's own Start, so nothing had populated the field at
      all before a rider's first-ever treadmill session. New,
      identically-named twin in `SettingsView` itself, run every time that
      screen appears (not gated on a connected treadmill – this screen has
      no connection to check in the first place, and reaching it at all is
      already a deliberate visit) – same "overwrite every time, only when
      Health actually has an answer" shape as its `ControlView` namesake.
      Placed alongside `prefillHeartRateProfileIfNeeded()`, but
      deliberately not sharing its gentler "only if still unset" logic –
      body weight, like resting heart rate, is treated as a Health value
      that genuinely drifts and is worth refreshing every visit, not a
      one-time default.
- [x] **Fixed a real labeling bug**: the treadmill device settings screen
      read "Seconds per 1° Incline" – reported directly, correctly, that
      this app has never measured incline in degrees anywhere, only
      percent (`TrainerConnection.inclinationRangePercent`, every treadmill
      target this app sends or displays). Fixed the visible text ("Seconds
      per 1% Incline", InfoButton reworded to "percentage point" throughout)
      and, since the underlying Swift naming had the same mismatch baked
      in, renamed `TrainerDeviceSettings.inclineChangeSecondsPerDegree` →
      `.inclineChangeSecondsPerPercent` (and its `default…`/`effective…`
      siblings) rather than leaving code and UI newly disagreeing with each
      other. The one real risk in a rename like this – `TrainerDeviceSettings`
      is `Codable`, decoded straight from `UserDefaults` JSON by property
      name with no explicit `CodingKeys` before this, so renaming the
      *stored* property outright would've silently dropped any value a
      rider already measured and saved on a real device the next time it
      loads – closed with a new explicit `CodingKeys` enum that keeps the
      JSON key exactly as `"inclineChangeSecondsPerDegree"` while the
      Swift-visible name reads correctly: a clean rename with no
      backward-compatibility cost, not a trade-off between the two.
      Localizable.xcstrings: renamed the two affected keys' entries in
      place (English source + German translation) rather than leaving the
      old, now-unreferenced ones behind as clutter.
- [x] **A third real crash, same signature, confirmed on a build that
      already had the previous two fixes** (`objc_msgSend` ←
      `__NSThreadPerformPerform` ← `__CFRunLoopDoSource0`, zero app frames,
      "possible pointer authentication failure" – see the two entries
      documenting `BLEDisconnectGracePeriod` and the Watch-companion
      `[weak session]` refactor above) – reported directly, with the one
      detail that actually narrows things down: no user interaction at
      all, ~25 minutes into the run. Investigated as thoroughly as an
      unsymbolicated, all-system-frames stack allows (this Mac still has no
      dSYM matching this specific build – see the very first crash
      investigation entry, above both of those, for why that search comes
      up empty every time) – swept every `NSObject`-conforming class in the
      app that sets itself as a system-framework delegate
      (`TrainerConnection`, `HeartRateConnection`, `BluetoothManager`,
      `WatchConnectivityManager`, the two `XMLParserDelegate` collectors,
      `DiagnosticsReporter`) for the same "released without a chance to
      protect itself" shape the first two fixes closed.
      Found one more real, independently-reachable instance:
      `BluetoothManager.connectHeartRate(to:)` – tapping a *different*
      strap's row in `DeviceListView` while already connected to one –
      used to overwrite `currentHeartRateConnection` outright, dropping the
      old `HeartRateConnection`'s last strong reference without ever
      calling its own `disconnect()` first, bypassing `BLEDisconnectGracePeriod`
      entirely (its `deinit` still ran, but that's the narrower catch-all,
      not the actual protection – same distinction the first fix already
      drew). Fixed by disconnecting the old connection first, same as
      `disconnectHeartRateCurrent()` already does on its own. Not a fit for
      *this specific* crash, though (it requires tapping a row, and there
      was no interaction that time) – a real bug, found along the way, not
      a confirmed explanation.
      Also hardened `BluetoothManager` itself with a `deinit` (`central?.stopScan()`)
      – it's `central`'s own `CBCentralManagerDelegate`, the same class of
      risk one level up, currently with zero protection of its own. Flagged
      honestly as weaker than the other fixes, though: under ordinary use
      this instance never actually gets deallocated at all (a `@StateObject`
      on the app's persistent root); the one path that would – `UnchainApp`
      `DeviceListView().id(languageOverride)` – has no equivalent to
      `TrainerConnection.disconnect()`'s "about to be released, still safe
      to act" checkpoint to hang a real `BLEDisconnectGracePeriod` call off
      of, and a language change doesn't fit "no interaction" either.
      Bottom line, stated plainly rather than overclaimed: two real,
      independently-valid hardening fixes came out of this investigation,
      but neither is a *confirmed* explanation for this specific incident –
      the crashed thread's own stack has no app code on it at all to point
      at one. If this recurs, a properly symbolicated report (Xcode
      Organizer, connected to the device that produced it, with matching
      debug symbols) is the way to actually pin down a real call site
      instead of continuing to reason from a blind system-only stack.
      Followed up with the one detail that actually narrowed this down:
      the Polar H10 strap connected that session is known to drop out on
      its own mid-workout (reported directly, as a recalled, plausible
      detail, not a confirmed cause either) – and `BluetoothManager
      .centralManager(_:didDisconnectPeripheral:error:)`'s own
      auto-reconnect for exactly that case is the *only* path anywhere in
      this app that re-issues a CoreBluetooth connection with genuinely
      zero user interaction (the trainer's own `reconnectCurrent()` only
      ever runs from a tapped button – no equivalent auto-retry exists for
      it). That handler used to call `central.connect(peripheral:options:)`
      straight back out from *inside* CoreBluetooth's own delivery of the
      disconnect that made it necessary – plausible reentrancy, and, for a
      strap that's genuinely flapping (intermittent skin contact), no gap
      at all between one drop and immediately reconnecting into the next
      one. Now deferred a second via `DispatchQueue.main.asyncAfter`
      instead of called inline – breaks the direct reentrancy and doubles
      as a natural debounce against exactly that flapping, rather than
      hammering `connect` in a tight loop – with a `[weak self]` plus a
      `currentHeartRateConnection === heartRate` identity check once the
      delay elapses, so a strap disconnected/switched out in the meantime
      doesn't get reconnected to by a now-stale retry. Still not provable
      as *the* cause from an unsymbolicated report – flagged as such
      deliberately – but the one concrete change actually motivated by
      what matches "no interaction" specifically, rather than a generic
      hardening pass.
- [x] **Fixed a genuinely separate real bug, spotted while testing right
      after that same crash**: relaunching the app and pressing "Workout
      starten" again looked like the *previous* (crashed) workout was
      still running – the same interval-list row highlighted as "current"
      varied between attempts, and the displayed elapsed duration itself
      started somewhere past 0, not at it. Confirmed first that nothing in
      this app persists `elapsedSeconds`/`startDate` across a relaunch at
      all (a fresh `WorkoutSession` genuinely starts at `elapsedSeconds =
      0` every time) – so the "leftover" value had to be coming from
      *outside* the app. It was: `refreshWorkoutState`'s existing
      clock-drift correction (see the entry documenting the crash that
      *that* itself was fixed from, much earlier in this log) trusts a
      connected machine's own `deviceElapsedSeconds` outright, on the
      premise that it's "the workout duration as far as the machine's own
      console is concerned" – true for correcting small, genuine drift
      over one continuous session, but not once the app crashes: nothing
      ever sent that treadmill a Stop, so *its* own elapsed-time counter
      never got told the workout ended either, and apparently just kept
      running (or held wherever it last reached) independently of the
      phone. A fresh session's very first tick could see a
      `deviceElapsedSeconds` minutes ahead of a local clock that had only
      been running a second or two, and jump straight into that stale
      position – varying by however long it had actually been since the
      crash, exactly as reported. Fixed with a plausibility bound: a
      connected machine's own counter is only trusted when it's within a
      minute of what the local clock itself expects (comfortably past any
      *real* drift or console-countdown discrepancy – both are ordinary
      quartz clocks, genuine drift is seconds, not minutes) – anything
      further ahead than that is treated as a stale leftover instead and
      quietly ignored, falling back to the local clock the same way an
      unreported `deviceElapsedSeconds` already did before this existed at
      all.
- [x] **Reacts to a device-initiated stop** (console Stop button, or an
      emergency/safety key pulled) – requested directly, prompted by the
      crash investigation above: an FTMS machine can physically halt with
      zero control-point command from this app involved at all, and this
      app had no way to even notice, let alone react – `WorkoutSession`
      just kept showing `.running`, still computing elapsed time and
      sending targets against a belt (or, in principle, a bike's own
      resistance unit) that had already stopped. FTMS defines exactly the
      characteristic for this – Fitness Machine Status (0x2ADA), the
      machine's own side of "something changed here", never a response to
      anything this app sent – previously undiscovered, unsubscribed,
      completely unhandled. Now discovered in its own separate
      `discoverCharacteristics` call (same "optional, shouldn't be able to
      take the essential control-point flow down with it" reasoning the
      speed/inclination range pair already established), subscribed to,
      and parsed for the two op codes (of the FTMS spec's full table) this
      app actually reacts to: "Stopped or Paused by the User" (0x02) and
      "Stopped by Safety Key" (0x03) – both published as a new
      `TrainerConnection.deviceInitiatedStopReason`.
      `ControlView` observes it and calls a new `WorkoutSession
      .pauseDueToDeviceStop()` – the same local state transition `pause()`
      itself makes (factored out into a shared `pauseLocalState()` once
      there were two callers), but deliberately *not* also sending
      `connection.pauseWorkout()` back to the device the way `pause()`
      does: the machine already told this app it stopped, sending it a
      command asking it to do exactly that again would be redundant, not
      corrective. Pausing, not stopping outright, mirrors what an
      app-initiated Pause already does – recoverable, the rider decides
      from here whether to resume or end the workout through the normal
      Stop flow – with an alert naming which of the two reasons it was
      (worded distinctly for the safety-key case, since that one's the
      more safety-relevant of the two). Not gated on machine kind either –
      the FTMS characteristic itself is generic across every machine type,
      not treadmill-specific, so a bike trainer with its own e-stop or
      physical button is covered exactly the same way. `deviceInitiatedStopReason`
      is cleared back to `nil` the moment `ControlView` reacts (new
      `TrainerConnection.acknowledgeDeviceInitiatedStop()`) – left standing
      otherwise, a second, later stop for the identical reason wouldn't
      register as a `@Published` change at all.
- [x] **Questioned directly, correctly: `maxPlausibleDeviceElapsedSecondsAhead`
      only bounded a *display* symptom** – the actual root cause is that a
      crash never sends the machine a Stop, so *its* own console never
      learns the workout ended either, and can keep going (or hold
      wherever it last reached) entirely on its own. The better fix:
      correct the machine's own state directly, not just decline to trust
      whatever it reports afterward. New `WorkoutSession
      .watchForOrphanedActiveWorkout()`, set up once in `init` – the very
      first genuine metrics notification a connection ever delivers (once
      both `hasControl`, so a stop command can actually be sent, and real
      data, not the placeholder `.empty` a fresh connection starts at) is
      checked for whether the machine already looks active – moving, or
      its own elapsed-time counter already ticking – despite this app's
      own session still sitting `.idle`. If so, `connection.stopWorkout()`
      is sent immediately. Deliberately one-shot (`.first()`), not an
      ongoing watch: FTMS notifications only start flowing once this app
      itself subscribes, moments after connecting, so there's no
      *legitimate* earlier window for a rider to have started walking on
      their own before tapping this app's own Start button – but there
      absolutely is a *later* one (warming up before officially starting),
      which this must not interfere with, and doesn't: only the one moment
      right after connecting is ever checked.
      `maxPlausibleDeviceElapsedSecondsAhead` itself stays – not replaced,
      kept deliberately as a second, independent layer: this new check
      only ever fires once, right after connecting, so it can't catch
      every conceivable way a stale reading might still show up later (a
      gap in this reasoning not yet found, a different device behaving
      unexpectedly, …) – cheap, harmless, general-purpose insurance
      underneath a fix that now actually addresses the real cause for the
      specific scenario reported.
- [x] **Found and fixed a real discontinuity in the treadmill power
      estimate** – reported directly, from actual empirical testing: below
      roughly 8 % incline, the pure climbing figure alone read far *below*
      what the flat-ground (internal-work) figure alone already showed at
      the same pace, meaning the displayed number visibly *dropped* the
      instant any incline was added at all, only climbing back out past it
      higher up – "Quatsch", correctly. Root cause was the switch-by-
      incline itself, not either formula individually: `climbingPowerWatts`
      and `internalWorkPowerWatts` were treated as mutually exclusive
      (climbing above 0 % incline, internal work at or below it), when
      physically both are genuinely present at every incline, all the
      time – a climbing runner is still swinging their limbs exactly as
      they were on the flat, on top of now also climbing.
      New `EnergyEstimator.treadmillPowerWatts(weightKg:speedKmh:inclinePercent:)`
      **sums** the two instead of switching between them – continuous
      across `inclinePercent == 0` by construction, not by a boundary case.
      Discussed adding only a *partial* share of the internal-work
      component while climbing (gait genuinely changes with grade, so it's
      plausible the true figure isn't a flat 100 % sum) – decided against
      inventing a specific fraction with no citation behind it: the
      literature already cited for the 0.3–0.6 J/(kg·m) range doesn't
      specify how that itself scales with incline, so picking some
      attenuation factor to look more sophisticated would just stack
      another unsourced assumption on top of an already-approximate model,
      not actually make it more accurate. Full 100 % sum stays, as the
      more honest simple choice absent better data.
      `WorkoutSession.EstimatedPowerSource` (the `.climbing`/`.internalWork`
      distinction the switch needed, and `ControlView`'s Watt tile used to
      decide when to color the value red) is gone along with the switch it
      existed for – every estimate now always includes the internal-work
      component, so there's no longer a case that's ever *purely* exact
      physics; the tile now colors red whenever it's showing this app's
      own estimate at all, not a real device reading, simpler than singling
      out one specific incline range.
- [x] **Both treadmill shorthand parsers understand a more natural-language
      phrasing** – requested directly, with a real example:
      `5 min warm-up @ 5 km/h with 5% incline, 5 x (3' @ 5,5 km/h and 13%,
      1' @ 5,0 km/h 6%), 5 min cool-down @ 4,8 km/h 4 %`. Started as a
      `docs/builder.html`-only ask; broadened directly to the app's own
      `TreadmillShorthandParser` too, with the actual goal named: "eine
      möglichst natürlichsprachliche Eingabe auch per Diktat" – dictation,
      not just quicker typing, so this went further than literally
      reproducing the one example.
      New in both: a filler-word stripper (`@`/`at`, `with`, `and`,
      `incline`, `warm-up`/`warmup`, `cool-down`/`cooldown`, word-boundary-
      anchored) applied before the existing length/speed/
      incline parsing runs unchanged, so "5 min warm-up @ 5 km/h with 5%
      incline" parses exactly like "5min 5km/h 5%" once stripped, with or
      without any filler word actually present. `'` (bare prime) for
      treadmill minutes, previously bike-only over a feet-ambiguity concern
      – revisited directly: the ambiguity is real in principle but not in
      practice (a treadmill interval a few feet long was never a plausible
      whole-step length), so it's accepted now for the same trade-off the
      bike side already made. A repeat count's own separator can now be a
      bare `x`/`X`, the multiplication sign `×` (dictation and some
      keyboards both produce it directly), or the spelled-out word
      `"times"` – whichever actually comes first in the segment, not a
      fixed priority order. Spelled-out English `"second"`/`"seconds"`/
      `"hour"`/`"hours"` added alongside the existing `"sec"`/`"h"` etc. –
      a real gap for dictation specifically, which is far more likely to
      produce a spelled-out unit than an abbreviation.
      Verified both parsers agree exactly, run against the same set of
      inputs (the full reported example, the original terse form for
      regression, spelled-out units, `times`, `×`, `at`) – a standalone
      Swift test harness (`swiftc`-compiled) and a Node.js one extracting
      the relevant functions straight out of `docs/builder.html`, same
      dual-verification approach this shorthand notation's very first port
      already established. The live browser click-through this session's
      own testing methodology otherwise favors hit real friction this
      time (the preview pane's profile toggle not reliably registering
      while the pane itself was backgrounded/hidden) – not chased further,
      since the actual parsing logic was already confirmed correct and
      identical in both languages without it.
- [x] **`docs/builder.html`: pasted treadmill shorthand now switches the
      Profile toggle itself, and "warm-up"/"cool-down" now actually shade
      the chart (and tag the `.zwo` export)** – both reported directly
      from an actual paste of the natural-language example above, with a
      screenshot: the chart stayed in whatever profile (Bike/Treadmill)
      happened to be active already, silently misreading treadmill-shaped
      shorthand against the bike grammar; and even once in the right
      profile, "warm-up"/"cool-down" were confirmed purely decorative,
      exactly as the (now corrected) entry above used to describe them –
      stripped for the numeric parse, discarded rather than shading
      `state.warmupBins`/`state.cooldownBins`, with the user's own
      suspicion that this skipped the `.zwo` export's own
      `<Warmup>`/`<Cooldown>` tagging too.
      New `looksLikeTreadmillShorthand(text)` – a treadmill step always
      names a speed target (`km/h`/`kmh`/`kph`/`mi/h`/`mph`), a bike step
      never does (always `%FTP`/watts), so that's a reliable, cheap
      signal – used by `applyShorthandText` to pick the parse grammar *and*
      set `state.mode` from the pasted text itself, the same way
      `applyZwoText` already sets it from a parsed file's own `sportType`,
      rather than trusting whichever profile happened to be selected
      before the paste; the symmetric case (pasting bike shorthand while
      in Treadmill mode) now switches back for the same reason, not
      explicitly asked for but a natural, low-risk companion to the
      treadmill case that was.
      `treadmillStepKind(text)` reads "warm-up"/"cool-down" off each
      step's own *original* text (before `stripTreadmillFillerWords`
      removes the words it's looking for) into a `"Warmup"`/`"Cooldown"`/
      `"SteadyState"` `kind`, threaded through
      `parseTreadmillShorthandBlocks`; `applyShorthandText`'s treadmill
      branch then reuses `applyZwoText`'s own scan-from-each-end algorithm
      to turn that into `state.warmupBins`/`state.cooldownBins` bin
      counts. Since `.zwo` export (`buildZwo`, via `classify(i)`) already
      reads those same two bin counts to choose `<Warmup>`/`<Cooldown>`/
      `<SteadyState>` per bin, the export side needed no separate change
      at all – the user's own suspicion was correct, and fixing the bin
      counts fixed the export as a direct consequence.
      Verified live in the browser this time (a local `http.server`
      serving `docs/` rather than a `file://` preview, sidestepping this
      session's earlier click-registration friction): pasting the exact
      reported example auto-selects Treadmill, shades both the warm-up and
      cool-down regions on the Speed and Incline charts, and the copied
      `.zwo` output tags the first block `<Warmup Duration="300" .../>`
      and the last `<Cooldown Duration="300" .../>` with every block in
      between `<SteadyState>`.
- [x] **`docs/builder.html`'s configured interval width can no longer
      collide with a parsed workout's own step granularity** – reported
      directly: a 5-minute width left selected while pasting a workout
      built from 1-minute steps needs fixing at the *width*, not just
      accepted as user error, since every `apply*Text` function only ever
      samples one value per bin (at its midpoint, or its own start/end for
      a ramp) – a bin wider than the shortest actual step can land that
      one sample past the step entirely, silently dropping it from the
      chart rather than just rendering it coarsely.
      New `autoFitBinSeconds(durationsSeconds)`, called by all four
      `apply*Text` functions (`.erg`/`.mrc`, `.zwo`, and both branches of
      shorthand) right before each computes its own bin count: shrinks
      `state.binSeconds` down to the greatest common divisor of the
      parsed data's own step durations whenever the currently configured
      width is coarser than that – GCD rather than just the shortest
      individual step, so every bin boundary lands on a real step
      boundary too and nothing blurs across one. Only ever shrinks, never
      widens back out on its own – a rider's own, deliberately coarser
      choice for a workout that doesn't need the extra resolution is left
      alone.
      The fixed "Interval length" 30s/60s/5m preset buttons (`#bin-select`)
      couldn't represent an arbitrary GCD result like this at all, so
      replaced with a freely typed field (`#bin-seconds-input`) instead –
      requested directly, alongside the actual bug. Styled and wired the
      same way `ftp-input` already is (a `.numfield` with a trailing unit
      `<span>`, `type="text" inputmode="numeric"` rather than the
      literally-suggested `type="number"`, for visual/behavioral
      consistency with every other numeric field this tool already has)
      rather than the native number-spinner control, worth flagging since
      it's a deliberate departure from the literal suggestion. Bounded to
      5–1800 s (`MIN_BIN_SECONDS`/`MAX_BIN_SECONDS`).
      Caught and fixed a real bug in `looksLikeTreadmillShorthand` (from
      the previous entry above) while building this: its speed-unit regex
      anchored a `\b` word boundary on *both* sides of the suffix, but
      this shorthand's own terse form always writes the number directly
      against the unit with no space ("5km/h", not "5 km/h") – a digit
      and a letter are both "word" characters, so there's no boundary
      between them, meaning the terse (and far more common) form was
      silently *never* detected as treadmill shorthand at all, only the
      spaced-out form the feature was first requested with. Fixed by
      anchoring only the trailing boundary. Verified live in the browser
      (a local `http.server`, not the `file://` snapshot used briefly
      earlier this session, which doesn't execute JS at all): setting a
      5-minute width, then pasting a 5min/90s/5min-shaped workout, shrinks
      it to 30s (the actual GCD) and parses correctly in both the terse
      and spaced forms; the field itself updates to reflect it.
- [x] **Both `.erg`/`.mrc`/`.zwo` export paths (app and web) now merge
      consecutive intervals holding identical data** – requested directly,
      for both. `docs/builder.html`'s own `buildZwo` already did this for
      its `<SteadyState>` blocks (`mergeRuns`); `ergLikeBody` (the shared
      body `buildErg`/`buildMrc` both call) didn't, writing one two-line
      breakpoint pair per bin unconditionally – now reuses that same
      `mergeRuns` helper, collapsing consecutive flat (`start === end`)
      bins holding the same value into one merged span; a ramped bin
      always keeps its own run (its `"ramp" + i` key is unique to that
      index), unchanged from before.
      On the app side, `WorkoutProgram.fileContents()` (bike `.erg`/`.mrc`)
      gained `mergedBreakpoints`, which drops any interior breakpoint that
      doesn't actually change the resulting piecewise-linear curve – i.e.
      one that already lies exactly on the straight line its own
      neighbors describe. One rule covers both the common case (a repeat
      group like `"5x(3min 200W)"`, which `ShorthandWorkoutParser.flatten`
      turns into five separate back-to-back 200W breakpoint pairs – all
      values equal, trivially "collinear") and the narrower case of two
      differently-built adjacent blocks merely sharing their boundary
      value, without two special cases. Provably safe – a genuine step
      change or an actual ramp-slope change always still needs both its
      own endpoints, so this never changes what
      `target(atElapsedSeconds:)` reports at any point in time, only
      shrinks the *file*. `TreadmillWorkoutProgram.fileContents()`
      (treadmill `.zwo`, both for a recorded free session and for one
      built via `TreadmillShorthandParser` – both reach this same
      function, see `WorkoutSession.fileContents`'s `.treadmillProgram`
      case) gained the simpler `mergedRuns`, combining consecutive
      segments sharing the same `speedKmh`/`inclinePercent` into one.
      Both applied only at export time, on a local copy – the stored
      `breakpoints`/`segments` themselves, and everything that reads them
      during a live workout, are untouched.
      Verified the app-side merge logic with a standalone `swiftc` test
      harness (five cases: a full repeat collapsing to its two endpoints,
      a genuine step change staying intact, a ramp followed by a flat
      continuation at the same ending value collapsing its one redundant
      point, two different-slope ramps meeting at the same value staying
      intact, and a genuinely collinear three-point ramp collapsing to its
      endpoints) and the web-side merge live in the browser
      (`"3x(3min 200W)"` exporting as a single `0.00→8.99 200` block
      instead of three).
- [x] **Fixed a real, shared parsing bug: a multi-line pasted workout (one
      top-level segment per line, not comma-joined) silently mis-parsed
      in every shorthand parser in both codebases** – surfaced by trying
      to parse a real bike example:
      ```
      10' warm-up @ 50% FTP
      12 x (30 secs @ 200%, 30 secs @ 30%)
      10' cool-down @ 50% FTP
      ```
      whose three lines are newline-separated at the *top* level (only
      the repeat group's own inner list uses a comma).
      `ShorthandNotation.splitTopLevel`/`shorthandSplitTopLevel`, shared
      by every shorthand parser in both codebases (bike and treadmill,
      app and web), only ever split on the literal `separator` character,
      never on a newline – so the whole three-line block silently read as
      a single, malformed top-level segment: no error, just a wrong,
      degenerate parse (in this case, only the very first `"10'"`
      warm-up duration ever actually got used). Fixed once, in the shared
      helper itself (normalizing every newline to `separator` before
      splitting), so every parser benefits, not just the one the bug was
      found through.
- [x] **Both bike shorthand parsers (app + web) understand the same kind
      of natural-language phrasing the treadmill ones already do** –
      requested directly, with a real example:
      ```
      10' warm-up @ 50% FTP
      12 x (30 secs @ 200%, 30 secs @ 30%)
      10' cool-down @ 50% FTP
      ```
      New in both `ShorthandWorkoutParser.swift` and `docs/builder.html`'s
      bike parser: a filler-word stripper (`@`/`at`/`with`/`and`/`warm-up`/
      `cool-down` – the same set `TreadmillShorthandParser`'s own strips,
      minus `incline`, meaningless for a bike step); a bare `"%"` target
      (no `"FTP"` suffix, e.g. `"200%"`) as an alias for `"%FTP"` – safe
      and unambiguous since this parser is deliberately power-only, no
      other percent-based target it could be confused with; and
      `"second"`/`"seconds"`/`"secs"`/`"hour"`/`"hours"` added to
      `durationUnits`/`BIKE_DURATION_UNITS`, matching the same forms
      `TreadmillShorthandParser`'s own units gained last time, plus `secs`
      specifically for this example. "warm-up"/"cool-down" stay purely
      decorative in this commit – see the next entry for the web-only
      follow-up that gives them real effect on the chart.
      Separately asked, directly: whether any real smart bike trainer
      actually supports a target-*speed* control mode, i.e. whether the
      bike parsers should ever need to understand `km/h` the way the
      treadmill ones do. No – FTMS does define a Set Target Speed op code
      (`0x02`) generically enough to apply to a bike too, but in practice
      no commercial trainer (Wahoo KICKR, Tacx NEO, Elite Direto, …)
      implements it for cycling: a bike's actual road speed depends on
      gearing and cadence the trainer doesn't control, so only ERG mode
      (Set Target Power) and/or Indoor Bike Simulation (grade/wind/Crr/Cw,
      itself resolving to a power target) are what's actually out there –
      confirmed by this app's own `TrainerConnection.setTargetSpeed(kmh:)`
      already being called exclusively behind `machineKind == .treadmill`
      everywhere in `ControlView`/`WorkoutSession`, never for a bike.
      Neither bike parser had any `km/h` parsing to begin with, so nothing
      needed removing – confirms the existing power-only design was
      already the right call, not a gap.
- [x] **Web builder: bike shorthand now also auto-switches the Profile
      toggle and shades warm-up/cool-down, mirroring the treadmill-side
      fix from earlier** – a natural companion to both fixes above,
      web-only. Threads a `kind` ("Warmup"/"Cooldown"/"SteadyState", from
      the new `bikeStepKind`) through to `applyShorthandText`'s bike
      branch, which now shades `state.warmupBins`/`state.cooldownBins`
      the same way the treadmill branch already does – built via a new
      `bikeBlocks` list (kept alongside the ramped-resampling `rows`,
      since `rows`' flattened breakpoint-pair shape has nowhere to carry
      `kind`). The near-identical scan-from-each-end algorithm
      `applyZwoText`, the treadmill branch, and now this bike branch all
      needed was finally factored out into one shared
      `scanWarmupCooldownBins` helper instead of staying inline three
      times over. `parseBikeShorthandRows` (now redundant – its own logic
      is inlined into `applyShorthandText` alongside the new
      `bikeBlocks` construction) was removed rather than left as dead
      code. Not ported to the app side – `WorkoutProgram` has no `kind`
      concept for a breakpoint the way `TreadmillWorkoutSegment` does
      (and no `.zwo`-style Warmup/SteadyState/Cooldown export to tag
      either), so "warm-up"/"cool-down" stay purely decorative there,
      same as they were for the treadmill app parser before that one
      specifically gained `TreadmillSegmentKind`.
- [x] **A build-stamp footer at the bottom of the Devices screen, and an
      automatically incrementing build number to go with it** – requested
      directly: "einen Versionshinweis mit dem aktuellen Git-Tag (ggf.
      plus Buildnummer) und einem Zeitstempel im ISO-8601-Format", plus
      how to auto-increment a build number at all.
      New `Scripts/stamp-build-info.sh`, run right after `xcodegen
      generate` (the Makefile's `generate` target – depended on by
      `build`/`install`/`run`/`archive`, so every one of those gets a
      fresh stamp) against the just-(re)written `Generated/Info.plist`:
      writes `git describe --tags --always --dirty` (a real tag once one
      exists – **none do yet in this repo**, `git tag v0.1.0` or similar
      is what starts giving this something more meaningful to show than
      the short commit hash `--always` falls back to; `--dirty` flags a
      local build made from uncommitted changes) into a new custom
      `UnchainGitDescribe` key, `git rev-list --count HEAD` (total commit
      count – strictly increases with every commit on a normal,
      append-only `main`, no stored/bumped state needed anywhere) into the
      real `CFBundleVersion`, and the build's own UTC timestamp
      (`date -u +"%Y-%m-%dT%H:%M:%SZ"`, genuinely ISO-8601) into
      `UnchainBuildTimestamp`. New `AppVersionInfo` (Swift) reads all
      three back via `Bundle.main.infoDictionary` into one footer string,
      e.g. `"9e6ec09-dirty (83) · 2026-09-10T10:48:11Z"`; `DeviceListView`
      shows it as a footer-only trailing `Section` at the bottom of its
      own `List`, omitted entirely rather than blank for a build that's
      never been through the stamp script at all.
      Deliberately does *not* also overwrite `CFBundleShortVersionString`
      with the git-describe string – that field has to be a plain
      dot-separated integer sequence for App Store Connect, which a
      describe string like `"v1.2.0-3-gabc1234"` (or a bare commit hash,
      right now) isn't; left alone for whatever marketing version gets
      deliberately set for a real release, independent of this.
      Tried this first as an Xcode Run Script build phase patching the
      *built* Info.plist instead (more conventional, and would refresh on
      every single Xcode build rather than only on `xcodegen generate`) –
      abandoned after `ENABLE_USER_SCRIPT_SANDBOXING` (project.yml, a
      "recommended settings" default) blocked it two separate ways at
      once: it denies the `git` subprocess reading `.git` at all unless
      every path it might touch is pre-declared (impractical for `git`,
      which reads all over `.git` depending on repo state), and separately
      denies writing back into the built Info.plist unless *that*'s
      declared as the script phase's own output too – which then collides
      with Xcode's own Info.plist-processing step already claiming to
      produce that exact file ("Multiple commands produce …"). Patching
      the *source* `Generated/Info.plist` as a plain shell step outside
      Xcode's build system entirely (this script, from the Makefile)
      sidesteps both problems at once – neither `git` nor `PlistBuddy`
      runs sandboxed there. The trade-off: a build launched straight from
      Xcode.app without `make generate`/`xcodegen generate` having run
      first just shows whatever `Generated/Info.plist` last had – decided
      this was worth it given this project's own CLI-first workflow
      (README, Makefile) already runs `generate` before every build
      anyway.
      `.github/workflows/ci.yml` switched from a bare `xcodegen generate`
      to `make generate` (picks up the same stamp step) and gained
      `fetch-depth: 0` on its checkout – the default shallow clone would
      otherwise silently under-count `git rev-list --count HEAD` there.
      README's own "Generating the project" walkthrough updated to lead
      with `make generate` instead of the bare `xcodegen generate` it had
      before, with a short note on what the extra step buys.
      Verified end to end: `make generate` → `PlistBuddy -c "Print
      :CFBundleVersion/…"` confirms the values land in
      `Generated/Info.plist`; a full `xcodebuild` confirms they survive
      into the *built* app's own `Info.plist` unchanged; a standalone
      `swift` script loading that built bundle directly (`Bundle(path:)`)
      and running `AppVersionInfo`'s exact read/compose logic against it
      confirms the footer string comes out correctly formatted. Not
      verified visually in the Simulator – Bluetooth is unavailable there
      (see README), so `DeviceListView` never gets past its own
      "Bluetooth unavailable" state to reach the `List`/footer at all;
      needs a real device to actually see it rendered.
- [x] **`docs/builder.html`'s "Interval Sketch" `<h1>` is now the editable
      current-workout name, written into a `.zwo` export's `<name>` and an
      `.erg`/`.mrc` export's `DESCRIPTION` line** – requested directly.
      The static `<h1>` became `#workout-name-input`, a plain `<input>`
      styled to disappear into looking exactly like the heading it
      replaced (same font/size/weight, no border/background of its own)
      until actually hovered/focused, matching this tool's own established
      pattern for every other editable field (`#ftp-input`,
      `#bin-seconds-input`) rather than `contenteditable` (which brings
      its own cross-browser paste/Enter-key quirks none of those need to
      deal with). New `state.name`, defaulting to `"Interval Sketch"`
      (`DEFAULT_WORKOUT_NAME`, restored on a blank/whitespace-only commit
      – same reasoning `ftp-input`'s own fallback-to-250 already has),
      persisted the same way every other field here is, read by
      `buildErg`/`buildMrc` (`DESCRIPTION = `) and `buildZwo` (`<name>`)
      in place of the old fixed, non-configurable `WORKOUT_NAME` constant
      they used before.
      Since `state.name` is now free-form rider text rather than a fixed
      constant, `buildZwo`'s own `<name>` interpolation needed real XML
      escaping for the first time – new `xmlEscape`, the same five
      predefined entities `TreadmillWorkoutProgram.xmlEscaped` already
      escapes in the app, applied only there (`.erg`/`.mrc`'s own
      `DESCRIPTION` is a plain-text format, nothing to escape, and can't
      contain an embedded newline in the first place since `<input>`
      itself can't hold one).
      `syncControlsFromState()` skips writing this field's own `.value`
      while it's actually focused – not a fix for a reproduced bug, just
      cheap insurance against `undo()`/`redo()` (clickable buttons, not
      just the keyboard shortcut a separate existing guard already
      excludes while typing) resetting the caret/selection mid-edit if
      they ever did fire while this field still had focus.
      Verified live in the browser: typing `"Bob & Alice's <Threshold>
      Test"` into the heading, confirmed the `.erg` export's own
      `DESCRIPTION` line keeps it verbatim and the `.zwo` export's `<name>`
      escapes it to `Bob &amp; Alice&apos;s &lt;Threshold&gt; Test` –
      re-parsed with `DOMParser` to confirm it's valid XML that round-trips
      back to the exact original text. Also verified the blank-input
      fallback (reverts to `"Interval Sketch"`) and that the name survives
      a page reload the same way every other field here already does.
      One known, accepted trade-off from switching to a plain `<input>`:
      the old `<h1>` could wrap a long name onto two lines
      (`text-wrap: balance`); an `<input>` is inherently single-line, so a
      long name just scrolls/clips within the field instead – not fixed
      here (would need an auto-growing `<textarea>`, a bigger, more
      foreign change than this tool's own "every editable field is a
      plain `<input>`" convention otherwise needs).
- [x] **`docs/builder.html`: an imported/parsed workout now shows "as is"
      (its own actual, variable-width step durations, no resampling onto
      any grid at all), with a new Cut tool to split an interval** –
      requested directly: the uniform bin grid only ever made sense for
      drawing a workout from scratch, and forcing a parsed one onto any
      fixed grid – however finely auto-fitted (see the interval-width
      entry two sessions back) – still bent it into a shape it never had.
      New `state.layout` (`"grid"` | `"segments"`) and `state.segments`
      (one entry per actual step, each carrying its own real
      `startSeconds`/`duration`, `kind`, and the same value fields a bin
      already had – `startWatts`/`endWatts` for bike, `speedKmh`/
      `inclinePercent` for treadmill). `applyErgLikeText`/`applyZwoText`/
      `applyShorthandText` all switched from resampling their parsed rows/
      blocks/steps onto `state.bins`/`state.binSeconds` to building
      `state.segments` directly from them instead – genuinely *simpler*
      code on every one of the three, not just more correct, since
      there's no resampling math left to do at all (the shorthand
      parsers' own step lists and a `.zwo` file's own blocks already
      *are* the exact segment shape needed). `autoFitBinSeconds`/
      `gcdSeconds`/`scanWarmupCooldownBins`/`resampleToBinsRamped`/
      `resampleToBins`/`valueAtMinutes` all lost every call site as a
      direct result and were removed rather than left as dead code – the
      auto-fit-width feature specifically existed to bound the damage a
      forced grid could do to a parsed workout, which building segments
      "as is" now solves at the root instead. The uniform grid stays
      exactly as it was – `state.layout` only ever becomes `"grid"` again
      for the bundled from-scratch sample workout a fresh session starts
      with.
      New Cut mode, modeled directly on an audio editor's razor/split
      tool (the user's own reference point): **C** enters it (segment
      view only; guarded against firing while typing, and against every
      modifier, so it doesn't shadow Cmd/Ctrl+C), a dashed guide line
      tracks the pointer rounded to the nearest second, and a click
      splits whichever segment is under it into two at that exact point –
      interpolating the value at the cut point for a ramped bike segment,
      so the ramp's own overall shape survives the split unchanged, the
      same way a razor splits a fading audio clip without altering the
      fade itself. **Escape** always exits it, deliberately *not* guarded
      against a focused text field the way **C** is – it doesn't do
      anything unwanted there either, and leaving Cut mode should always
      work regardless of where focus happens to be.
      Segment view got its own, deliberately narrower parallel rendering/
      interaction path (`renderSegmentLane`/`ensureSegmentLaneSetup`,
      `renderLaneForMode` picking between it and the untouched
      `renderLane`/`ensureLaneSetup` on `state.layout`) rather than
      folding variable-width geometry into the existing bin-indexed one –
      same visual language (gradient fill, accent colors, gridlines,
      warm-up/cool-down bands – now read straight off each segment's own
      `kind`, no bin-count derivation needed there at all any more) but
      every position is time-based (`PX_PER_SECOND`) instead of per-bin.
      Vertical-drag-to-set-a-flat-value works in segment view too (the
      same "which segment is under the pointer" lookup Cut needs anyway),
      but ramped edge-dragging and the warm-up/cool-down drag handles –
      grid view's most intricate gestures – are **not** ported; the
      "Preview" textarea (already-exported text, live re-parsed on every
      edit) stays a fully general fallback for anything not covered
      there directly. Interval Length/Intervals/Warm-up/Cool-down – none
      of them mean anything for variable-width segments – are hidden in
      segment view, replaced by a hint naming the **C** shortcut.
      `mergeRuns` (already used for grid-view export) reused as-is for
      segment-view export too, just keyed by segment index instead of bin
      index – `ergLikeBody`/`buildZwo` both gained a segment-mode sibling
      that still merges consecutive identical-value runs into one block
      (a `.zwo` run additionally keyed by `kind`, matching grid view's
      own `classify`-based behavior, so a same-value Warmup segment never
      silently merges into a following SteadyState one).
      Verified extensively: a standalone Node harness feeding a ramped
      `.erg`, a bike shorthand string with a warm-up/12×interval-pair/
      cool-down, and a treadmill shorthand string through
      `applyErgLikeText`/`applyShorthandText` confirmed `state.segments`
      matches the source step-for-step (right down to a step-change pair
      at the same timestamp correctly producing *no* zero-duration
      segment); a second harness confirmed `ergLikeBody`'s and
      `buildZwo`'s segment-mode export merge/preserve exactly as
      expected. Live in the browser (a local `http.server`, native
      `DOMParser` needed for the `.zwo` import path Node can't exercise):
      pasting each of the three shorthand/zwo examples above rendered
      genuinely variable-width blocks with correct warm-up/cool-down
      shading; entering Cut mode showed the snapped guide line, and a
      click split a segment – confirmed by painting the two resulting
      pieces to different values and seeing both the chart and every
      export (`.erg`/`.zwo`) reflect two independent pieces where there'd
      been one, on both the bike Power lane and the treadmill's two
      synced Speed/Incline lanes together (a single cut on either lane
      correctly split the one shared segment both read from). Grid view
      itself re-verified unaffected afterward – a fresh session (cleared
      storage) still shows the classic bundled sample workout, paints,
      and drags exactly as before.
- [x] **Fixed a real bug found while testing the segment-view feature
      above: pasting a `.zwo` file often silently failed to parse as one
      at all** – reported directly. `handlePreviewEdit` used to decide
      *which* parser to run a pasted file-shaped text through by reading
      whichever `.jack button.active-fmt` (the ".erg"/".mrc"/".zwo"
      *download* tab) happened to be selected – a control for choosing
      what to export next, with no reason to already be set to ".zwo"
      before an unrelated paste, and ".erg" by default on every fresh
      session. Pasting a `.zwo` file straight after opening the page (or
      after last downloading an `.erg`) tried to parse it as `.erg`
      instead, which fails outright (no `[COURSE DATA]` in a `.zwo`
      file).
      New `detectImportFormat(text)` reads the format straight off the
      pasted text's own shape instead – `<workout_file>` is unambiguous;
      `.erg` vs. `.mrc` is exactly the same `WATTS`/`PERCENT` header-line
      distinction `buildErg`/`buildMrc` themselves already write, read
      back the same way – the same "detect from the content, don't trust
      whichever unrelated control happens to be selected" fix already
      applied to `applyShorthandText`'s own bike/treadmill detection.
      `handlePreviewEdit` now also calls the new shared `setActiveFmt`
      helper with the detected format, so the Preview label and
      highlighted download card visibly follow what was actually just
      pasted too, not just the internal parse choice.
      Verified live with the user's own real example (a 16-block "Pyramid
      Of Hill Climb Intervals" `.zwo`, treadmill, mixed short graduated
      steps and long holds) pasted while the ".erg" tab was still the
      default active one: parsed successfully (previously would have
      failed), auto-switched Profile to Treadmill and the download tab to
      ".zwo", and round-tripped through the `.zwo` export byte-for-byte
      identical to the source (every block's own Duration/Pace/Incline
      unchanged – the segment-view work above meant nothing to reconcile
      onto a grid at all). Also re-verified `.mrc` detection specifically
      (a bare `%`-based file, `FTP =` header) still resolves to the
      correct absolute watts via the file's own declared FTP, now
      independent of the active tab there too.
- [x] **`docs/builder.html`: `.zwo` `<TextEvent>` tags now show as
      markers on the segment-view chart, are editable/creatable with a
      new Mark mode, and export back out** – requested directly, as a
      multi-part follow-on to the segment-view work above (its variable-
      width `state.segments` array is exactly what makes a marker's own
      `timeoffset` – seconds from its *containing block's* own start –
      trivial to keep exact through a Cut, since each segment already
      tracks its own `startSeconds`). Spec confirmed against the
      reference page's raw source directly (a first pass through the
      fetch tool inferred an example that wasn't actually there) rather
      than trusted secondhand: `<TextEvent message="…" timeoffset="…"
      Duration="…"/>` nested inside `Warmup`/`SteadyState`/`Cooldown` –
      `timeoffset`/`TimeOffset` both appear in real files (lowercase
      dominant, ~7500:1), read case-insensitively via a small
      attribute-lookup helper rather than trusting exact casing.
      Every segment gained its own `textEvents: []` array (populated
      only by `applyZwoText`; ERG/shorthand imports have no text-event
      concept and always default to empty), rendered as a small pin +
      dashed full-height guide line + truncated label (native `<title>`
      tooltip for the full text) on every lane of `renderSegmentLane` –
      both Speed and Incline for treadmill, matching how warm-up/
      cool-down shading already renders redundantly per-lane.
      Clicking an existing marker edits (or, on a blank submission,
      deletes) its text via `window.prompt` – hit-tested against the
      same single transparent per-lane hit-rect every other segment-view
      interaction already uses (time-distance plus a small y-band near
      the top, checked *before* falling through to ordinary painting),
      rather than giving markers their own clickable elements that would
      sit under that hit-rect and never actually receive a click.
      New Mark mode, structurally the twin of Cut mode above: **M**
      enters it (same typing/modifier guards, mutually exclusive with
      Cut, sharing its one guide-line element rather than duplicating
      it), a click sets a marker at that point and immediately prompts
      for its text; **Escape** exits either mode the same unconditional
      way. A cut through a marker-bearing segment redistributes its
      events by *absolute* time rather than moving them: anything before
      the cut point stays on the first new piece with its offset
      unchanged (that piece's own start didn't move), anything at/after
      it moves to the second piece with its offset recomputed relative
      to *that* piece's new start – "an audio editor's razor doesn't
      move a marker, only which clip it's now part of." Export
      (`buildZwo`'s segment-mode branches, via a new shared
      `pushZwoBlock` helper) always treats an event-bearing segment as
      its own unique, non-mergeable run – the same trick already used
      for a ramped bike segment – sidestepping ever having to re-express
      an event's offset relative to a *merged* block's start.
      Verified live end-to-end for the bike case: parse → render
      (screenshot-confirmed pin/label/tooltip) → edit → create via Mark
      mode → cut a SteadyState with events at offset 0 and 90 at offset
      60 (correctly became a 60s piece keeping offset 0, and a 120s
      piece with offset recomputed to 30, both confirmed in the
      re-exported `.zwo`) → delete via a blank prompt (reverted to a
      self-closing block tag on export). Treadmill re-verified
      separately: a Warmup/SteadyState-with-marker/Cooldown run file
      parsed and synced correctly (total time, mode), and the marker
      rendered correctly on *both* the Speed and Incline lanes at the
      same x-position, confirming the per-lane drawing loop isn't
      bike-only.
- [x] **The app itself now reads `<TextEvent>` tags during `.zwo` playback
      and shows them as an animated coaching-cue overlay** – the direct
      app-side follow-on to the `docs/builder.html` work above, requested
      alongside it. `ZWOWorkoutParser` gained `<TextEvent>` support: a new
      `TextEventMarker` (`timeOffset`/`message`/optional `duration`,
      exactly mirroring `docs/builder.html`'s own marker shape) collected
      into each `TreadmillWorkoutSegment`'s new `textEvents` array while
      its containing `Warmup`/`SteadyState`/`Cooldown` block is open (a
      `<TextEvent>` is only ever seen *after* its parent's own opening
      tag, so the collector tracks which segment index is currently
      open), read case-insensitively (`timeoffset`/`TimeOffset`, same
      real-world casing split as the web tool's own attribute lookup).
      `textEvents` needed a custom `init(from:)` for `TreadmillWorkoutSegment`
      to decode – confirmed directly (not just assumed) that a
      non-`Optional` stored property's default value, unlike an
      `Optional` one such as `kind`, is *not* actually honored by
      synthesized `Decodable` for a genuinely missing key, so a
      `TreadmillWorkoutProgram` persisted before this existed needed that
      spelled out explicitly rather than relying on the property default
      alone.
      New `TreadmillWorkoutProgram.activeTextEvent(atElapsedSeconds:)`
      finds whichever marker's own `[start, start + duration)` window
      (falling back to a named `TextEventMarker.defaultDurationSeconds`
      of 5 s when the file leaves `Duration` unset – Zwift itself doesn't
      document a default, so this is a deliberate, named app-side choice,
      not treated as if the file had said something it didn't) contains
      the current position – called once per tick from
      `WorkoutSession.sendCurrentWorkoutTarget(for:)`'s `.treadmillProgram`
      case into a new `@Published private(set) var activeTextEvent`
      (`nil` for `.program`/`.route`, which have no such concept, and
      explicitly cleared on `stop()` so it can't linger over the save/
      discard dialog).
      `ControlView` observes it through a new `TextEventOverlayView`,
      pinned to the main `ScrollView`'s own viewport (`.overlay(alignment:
      .top)`) so it stays visible regardless of scroll position, rather
      than living inline in the scrolled content. Asked directly for
      animation ideas before writing any of this – presented four options
      (slide-and-fade toast, scale-pop + blur-dissolve, a countdown-wipe
      tied visually to `Duration`, and a typewriter reveal) and the rider
      picked **Scale-Pop + Blur-Dissolve**: the card springs in from
      slightly small and transparent up to its natural size on entry (a
      quick, energetic "pop"), and on exit deliberately *isn't* just that
      reversed – it grows slightly *past* natural size while blurring and
      fading out, reading as the message dissolving away rather than
      mechanically shrinking back down. Built as a small, reusable
      `AnyTransition.scalePopBlurDissolve` (an asymmetric transition whose
      two halves each carry their own `.animation(_:)` – a spring for
      entry, a plain ease-out for exit – which is what makes it animate at
      all without any `withAnimation`/`.animation(_:value:)` at the call
      site) over a `TextEventTransitionModifier` combining `.scaleEffect`/
      `.blur`/`.opacity`. Each card gets a stable `.id()` off its own
      `timeOffset`/`message` so two markers reached back-to-back (the
      first's window closing right as the second's opens) still each run
      their own full entry/exit transition instead of the content just
      updating in place.
      Verified the parsing/lookup logic with a standalone harness (mixed
      `timeoffset`/`TimeOffset` casing, an explicit `Duration=6`, and a
      `Duration`-less marker) confirming `activeTextEvent(atElapsedSeconds:)`
      returns the right marker across an explicit window, correctly falls
      back to the 5 s default for the unset one, and correctly returns
      `nil` exactly at a window's own end (half-open, as intended) – and
      confirmed the whole app still builds clean (`xcodebuild build`,
      Debug, Simulator SDK) with the new code in place. Genuine on-device
      playback verification (an FTMS treadmill actually running a `.zwo`
      file with `<TextEvent>` markers) wasn't done in this pass – per this
      project's own long-standing constraint (see the README), Bluetooth
      doesn't work in the Simulator at all, so that step still needs a
      real ride.
- [x] **`docs/builder.html`: grid view and segment view are now one
      implementation, not two** – reported as a regression first (Shift+
      drag ramp-edge editing "stopped working"), traced to its actual
      cause, and fixed at the root rather than patched twice. The
      previous session's segments feature left two entirely separate
      chart representations side by side – a fixed-width bin grid
      (`renderLane`/`ensureLaneSetup`, only ever used for a from-scratch
      workout) and variable-width segments (`renderSegmentLane`/
      `ensureSegmentLaneSetup`, used for anything imported) – and Shift+
      drag ramp editing only ever existed in the grid one. Since every
      real workout (anything imported/pasted) uses segment view, that
      read as "broken" even though it only ever worked on a from-scratch
      grid workout to begin with. Rather than reimplementing the gesture
      a second time against segments, treated grid as what it actually
      is: N equal-duration segments, `kind` already able to carry
      Warmup/SteadyState/Cooldown per segment. `state.bins`/`power`/
      `speed`/`incline` are gone entirely – `state.segments` is the only
      per-workout data now, for both.
      Two problems surfaced while designing this, both resolved before
      writing any code: (1) the old `power`/`speed`/`incline` arrays
      always existed *together*, regardless of which Profile was
      showing, which is what made toggling Bike ↔ Treadmill on a from-
      scratch workout lossless – a single flat `segments` array would've
      broken that. Fixed by mode-namespacing it instead:
      `state.segments = { bike: [...], treadmill: [...] }`, with a new
      `activeSegments()` (`state.segments[state.mode]`) the only thing
      rendering/interaction/export ever reads or writes; the grid-only
      export path (`.erg`/`.mrc`, Power-only formats with no Treadmill
      equivalent) reads `state.segments.bike` explicitly rather than
      `activeSegments()`, so downloading it while Treadmill happens to be
      the displayed Profile still exports the right data, not whatever's
      currently on screen. (2) `performCut` splits a segment into two
      *unequal*-duration pieces – the instant that happens to a grid
      workout, every grid-only assumption (interval-length rescale,
      intervals-count resize, the boundary handles, warm-up/cool-down
      counts) stops holding. Fixed by promoting `state.layout` from
      `"grid"` to `"segments"` the moment a cut actually splits something,
      right in `performCut` itself – hides the Interval Length/Intervals/
      Warm-up/Cool-down fields and boundary handles from then on (the
      existing toolbar-visibility toggle already does this correctly off
      `state.layout` alone), the honest framing that a surgically-cut
      workout isn't a uniform grid anymore. Marking a segment doesn't
      change its count/width, so Mark alone leaves a grid workout as
      grid.
      Ramp-edge Shift+drag, sideways multi-segment paint-drag
      interpolation, and endpoint snapping – all three previously
      grid-only – are ported into `ensureSegmentLaneSetup`, addressed by
      segment index/real seconds (`PX_PER_SECOND`) instead of bin index/
      pixel-width, and now work for *both* kinds of workout – the actual
      fix, plus closing a second latent gap (imported workouts never had
      sideways-paint interpolation or snapping either, only ever a single
      flat set-this-one-segment paint). Cut and Mark, previously gated to
      segment view only because grid view had no `state.segments` to
      operate on, lost that gate too – both now work on a from-scratch
      workout the same way. Only the warm-up/cool-down drag handles stay
      grid-workout-only, deliberately – landing one on an arbitrary,
      unevenly-spaced existing segment boundary in a real imported file
      is a materially harder problem than this needed to solve; Cut
      first, then paint, is the way to shape an imported workout's warm-
      up/cool-down region instead.
      One more real (if minor) behavior change along the way: the
      "Interval Length" field used to silently do nothing to the actual
      data – it only relabeled the time axis, a latent, confusing quirk
      sitting right next to "Intervals." Now it genuinely rescales every
      grid segment's own duration (`rescaleGridSegments`), which is what
      the field's own name always implied it did.
      `UNDO_FIELDS` and localStorage both got smaller (`bins`/`power`/
      `speed`/`incline` dropped) as a direct consequence – a saved-before
      -this blob needed a one-time migration on load, `migrateOrAdopt
      Segments`, covering: already-current `{bike,treadmill}` shape
      (pass through), the previous session's own flat `segments` array
      (attributed to whichever Profile/`layout==="segments"` it recorded),
      and genuinely old grid-only arrays (`gridArraysToSegments`
      synthesizes both Bike and Treadmill segment arrays from them,
      folding in what a since-removed `normalizePowerBins` used to do for
      even-older plain-number `power` entries) – falling back to a fresh
      sample for whichever side has nothing usable in a given save.
      Verified extensively in the browser (a local `http.server`, direct
      `PointerEvent` dispatch via `javascript_exec` – established this
      session as more reliable than the `computer` tool's simulated
      clicks against these SVG hit-rects): on the default grid sample –
      plain paint, sideways-paint interpolation (confirmed against hand-
      computed interpolated values), Shift+drag ramp-edge editing with
      snap-to-neighbor engaging correctly, a warm-up boundary-handle drag
      correctly re-tagging the crossed segments' own `kind` (confirmed in
      the exported `.zwo`), Cut correctly promoting to segment view (and
      Undo correctly reverting it), Mark correctly *not* promoting it,
      and a Bike ↔ Treadmill toggle correctly leaving both profiles'
      edits untouched across the switch. On an imported ramped shorthand
      workout – confirmed Shift+drag ramp-edge editing now works there
      too (the actual reported bug), reflected correctly in the
      re-exported `.erg`. Migration verified against two hand-written
      legacy localStorage blobs (an old grid-shaped one and an old flat-
      `segments`-shaped one), both loading correctly with both profiles
      populated, round-tripping cleanly through a second reload without
      re-triggering migration.
- [x] **`docs/builder.html`: Treadmill's Speed and Incline lanes can now
      be ramped too, Shift+drag, the same gesture Bike Power already
      has** – requested directly as the direct follow-on to the grid/
      segment unification above. Each treadmill segment's flat
      `speedKmh`/`inclinePercent` fields became independent `start`/`end`
      pairs (`startSpeedKmh`/`endSpeedKmh`, `startInclinePercent`/
      `endInclinePercent`) – Speed and Incline ramp independently within
      one segment, not tied together. `lanes.speed`/`lanes.incline` both
      gained `hasRamps: true` plus `segSetStart`/`segSetEnd` accessors
      alongside their existing `segStart`/`segEnd`/`segSet` – since the
      interaction layer (`ensureSegmentLaneSetup`) already addressed
      ramp-edge dragging entirely through those lane-config accessors
      (built that way for exactly this reason when Bike got it), enabling
      it for two more lanes needed no changes there at all, only to the
      data each lane's accessors point at.
      Every place that built, split, or exported a flat treadmill value
      needed the shape update: the default sample builder, `.zwo`/
      shorthand import, `performCut` (now interpolates Speed and Incline
      independently at the cut point, mirroring Bike's own ramp-split),
      `resizeSegments`'s "continue from the previous last segment" logic,
      the Speed-step re-rounding handler, and `buildZwo`'s Treadmill
      branch – a ramped segment (either field, independently) now keeps
      its own unique, non-mergeable export block and writes its `Pace`/
      `Incline` as the start/end average, exactly the same "can't express
      a ramp in `.zwo`, so average it" rule Bike's own ramped segments
      already followed there.
      A genuinely pre-existing localStorage save has treadmill segments
      in the old flat shape – new `normalizeTreadmillSegment` upgrades
      one in place (same reasoning `normalizePowerBins` already had for
      Bike), called from `migrateOrAdoptSegments`. Caught a real bug
      here during testing: the *already-current-container-shaped* early-
      return branch of that function (a save from after grid/segments
      were unified but before this) skipped normalization entirely,
      producing `NaN` throughout the chart and every export – fixed by
      normalizing on that branch too, not just the ones that actually
      synthesize `segments` from scratch.
      Verified live in the browser: Shift+drag ramp-edge editing on both
      Speed and Incline independently (confirmed via the readout and the
      re-exported `.zwo`'s correctly start/end-averaged `Pace`/`Incline`
      for that one now-unique block); cutting through a doubly-ramped
      segment (both Speed and Incline ramped at once) split it into two
      pieces whose values meet exactly at the cut point, confirmed
      against hand-computed interpolation for both fields independently;
      the pre-existing-save migration bug above, confirmed broken (NaN
      everywhere) before the fix and clean (correct chart, correct
      export, zero console errors from a genuinely fresh tab) after it.
- [x] **`docs/builder.html`: drag & drop a `.erg`/`.mrc`/`.zwo` file onto
      the Preview field, or directly onto the chart, to load it** –
      requested directly, then extended to the chart itself as a direct
      same-session follow-on, alongside pasting one (already supported)
      as a more direct way in. Deliberately not its own parse path: a
      drop just sets the Preview textarea's own `.value` to the dropped
      file's text and calls `handlePreviewEdit()` directly – the exact
      same function a paste's own `input` event already triggers, which
      itself detects erg/mrc/zwo/shorthand from the text's own shape
      (`detectImportFormat`/`looksLikeWorkoutFile`) and already reports a
      parse failure via `#sync-status`, regardless of which of the two
      drop zones the file actually landed on – so nothing here needed its
      own extension check or error handling beyond a failed *read* of the
      file object itself.
      New `attachFileDropZone(dropEl, highlightEl)` wires one drop
      target, called for both `#preview-text` and the chart's own
      `.scope-wrap` (the whole card – SVG, lane labels, and hint text
      together, so a drop anywhere in the chart area counts, not just
      exactly on the `<svg>`; doesn't conflict with the chart's own
      pointer-based paint/Cut/Mark interaction at all, since drag events
      and pointer events are entirely different event types).
      `highlightEl` (defaulting to `dropEl`) is what actually gets the
      dashed `.drag-over` outline – kept as a separate, generic CSS class
      rather than folded into the textarea's own rule, since the
      textarea additionally tints its background on drag-over, which
      would look wrong on the chart card (its own children already have
      their own backgrounds). `dragenter`/`dragover` are only handled
      (and only show the outline) when the drag actually carries a file
      (`dataTransfer.types` includes `"Files"`, checkable before `drop`
      unlike `.files` itself) – an ordinary text/link drag isn't
      intercepted anywhere, falls through to the browser's own default
      behavior untouched. `file.text()` (a `Promise`, same pattern the
      existing Copy button's `navigator.clipboard.writeText(...).then(...)`
      already uses) reads the dropped file; a read failure (not really
      reachable for a local file drop in practice, but handled anyway)
      shows "couldn't read that file" the same way a parse failure shows
      its own message.
      Verified live in the browser (synthetic `DragEvent`-shaped `Event`s
      carrying a real `File`, dispatched directly on the target element –
      `DataTransfer` itself can't be constructed with real files from
      script, so a plain object with `types`/`files` stood in, which is
      all the handlers actually read): dropping a `.zwo` file on the
      Preview field, and a `.erg` file directly on the chart's `<svg>`
      (bubbling correctly up to `.scope-wrap`'s own listener), both
      parsed correctly and switched the active download tab to match;
      dropping a genuinely unparseable file showed the existing
      "couldn't parse yet" error without crashing; a plain text-only drag
      (no `Files` type) correctly left both fields untouched; ordinary
      chart painting (a plain `pointerdown`/`pointerup` on the same
      `<svg>`) still worked correctly afterward, confirming the new drag
      listeners don't interfere with the chart's own interaction layer;
      the dashed outline correctly wraps the whole chart card, in both
      Bike and Treadmill mode.
- [x] **Removed the in-app "Create Workout" shorthand builder entirely** –
      requested directly: `docs/builder.html`'s own "Interval Sketch" is
      now the one and only Workout Builder, and the in-app one (typing a
      shorthand string into a sheet, `CreateWorkoutView`, reached via a
      "Create" button next to "Load from File"/"Recent") was always a
      narrower stopgap next to it – no chart to actually see/adjust what
      you're typing before saving, no drag-and-drop, no file import at
      all, none of the segment-view features (Cut/Mark/ramp-editing) the
      web tool has now. Deleted outright rather than deprecated:
      `Unchain/Views/CreateWorkoutView.swift`, `Unchain/Models
      /ShorthandWorkoutParser.swift` (bike grammar), `Unchain/Models
      /TreadmillShorthandParser.swift` (treadmill grammar), and
      `Unchain/Models/ShorthandNotation.swift` (the low-level tokenizing
      the two parsers shared – `consumePrefixedValue`/`splitTopLevel` –
      nothing else in the app used it). `ControlView`'s "Create" button,
      its `isShowingCreateWorkout` sheet presentation, and the
      `canCreateShorthandWorkout` gating property all went with it;
      `loadProgramIntoSession`/`loadTreadmillProgramIntoSession` –
      shared with "Load from File" and "Recent" – were untouched, since
      those two remain exactly how a workout gets into a session now.
      `WorkoutProgram`/`TreadmillWorkoutProgram` themselves (the actual
      playback models, driving *any* loaded workout regardless of
      source) and the file-based parsers (`WorkoutProgramParser`,
      `ZWOWorkoutParser`) are untouched – only the *typed-shorthand*
      production path is gone, not what plays a program back.
      Several doc comments elsewhere referenced the deleted feature as
      context (why a merge-collinear-breakpoints rule exists, why
      `ftpWattsKey` is `static`/shared, why `intensityAdjustmentPercent`
      says "file" not "file/shorthand") – reworded in place rather than
      left dangling, in `WorkoutProgram.swift`, `TreadmillWorkoutProgram
      .swift`, `WorkoutSession.swift`, `SettingsView.swift`, and
      `ControlView.swift`'s own `paceString(fromSpeedKmh:)` (which
      doesn't call into the shorthand parsers at all – it only borrowed
      their prime/double-prime `'`/`"` notation as a "stay consistent"
      justification that no longer applies now that notation isn't used
      anywhere else in the app; the function and its own formatting are
      otherwise completely unaffected). Removed README.md's "a true
      free-form 'describe your workout' prompt" idea-for-later section
      too – its whole premise (evolving the in-app shorthand into an
      LLM-driven prompt) no longer has an in-app shorthand to evolve
      from. 17 now-orphaned `Localizable.xcstrings` entries (the "Create"
      button, "Create Workout"/"Custom Workout", the Form's own "Name"/
      "Preview" section headers, both grammar hints, and all 10 of the
      two parsers' own error messages) removed too – cross-checked each
      one first (`grep`) to confirm nothing else in the app still uses
      that exact source string, since an `.xcstrings` key is shared by
      source text, not by call site; "Workout"/"Duration"/"Cancel"/"Save"
      collided with still-live keys elsewhere and were correctly left
      alone.
      Verified clean: full-codebase `grep` for every deleted symbol name
      confirmed zero remaining references anywhere (Swift, `project.yml`,
      README); `xcodebuild build` (Debug, Simulator SDK) succeeded, and
      its own "Removed stale file" notes confirmed the four deleted
      source files' compiled objects were actually gone from the build
      too, not just absent from the file list.
- [x] **`docs/builder.html`: replaced Cut/Mark *modes* with direct,
      always-on hover interaction** – requested directly: instead of
      pressing C or M to enter a mode (a guide line only then appearing,
      a click needed to actually commit), a thin hover line and a
      highlighted segment now always track the pointer over any lane's
      chart, and "C"/"M"/"Delete"/"Backspace" act immediately, right
      where the pointer already is – cut, mark, or delete that segment,
      no click needed at all. New shared `hoverSeconds` (`null` whenever
      the pointer isn't over any chart) is what makes this possible:
      every lane's own `pointermove` keeps it current and repositions
      that lane's hover line/segment highlight; `pointerleave` clears it
      back to `null`; the one keydown listener for C/M/Delete/Backspace
      simply does nothing while it's `null`. Shared across lanes
      (Speed/Incline on a treadmill), not lane-local – a cut/mark/delete
      acts on the one segment list underlying both, whichever lane's
      chart the pointer happens to be hovering; verified a cut made
      while hovering Speed is immediately visible as a new boundary on
      Incline too. Also reset on a Profile switch (Bike ↔ Treadmill) –
      the previously-hovered lane's `#lanes-bike`/`#lanes-treadmill`
      ancestor gets hidden via `display:none` without ever firing its
      own `pointerleave`, which would otherwise leave `hoverSeconds`
      stale, pointing C/M/Delete at a chart that's no longer even
      visible; confirmed a bare press right after switching (no re-hover
      yet) is correctly a no-op.
      New "Delete"/"Backspace" (`performDeleteSegment`) removes the
      hovered segment entirely and ripples every later segment earlier
      by its own duration to close the gap – this data model has no way
      to represent a gap at all (segments are always contiguous), so
      that's the only shape that stays valid, the same way deleting a
      clip in an audio editor's own timeline closes the hole instead of
      leaving silence. A no-op if it's the only segment left (verified:
      deleting down to exactly one, then trying again, correctly does
      nothing). Same "breaks the grid's own uniform-width invariant"
      promotion `performCut` already had – deleting a segment from a
      grid workout now promotes it to "segments" too, verified alongside
      confirming Undo correctly reverts that promotion (grid-only fields
      reappearing) right along with the delete itself, and Mark's own
      undo needing no such revert since it never promotes.
      `EDGE_HIT_PX`/`segEdgeAt`/Shift+drag ramp editing, plain painting,
      and marker-click-to-edit are all untouched – only the Cut/Mark
      *mode* mechanism is gone, confirmed both still work exactly as
      before. Also fixed in passing: a genuinely orphaned doc comment
      for `renderLaneForMode`, a function deleted in the grid/segment
      unification two entries up but whose own doc comment was
      accidentally left behind, sitting in front of unrelated code ever
      since.
      Verified extensively live in the browser (direct `PointerEvent`/
      `KeyboardEvent` dispatch): hover line + segment highlight both
      track the pointer and update on every move; "M" prompts and adds a
      marker at the exact hovered second with no prior mode-entry; "C"
      cuts at the hovered second (confirmed the resulting two pieces'
      own time ranges via the readout); "Backspace" deletes the hovered
      segment and the workout's total time shrinks by exactly its
      duration; all three fully reversible via Undo, including the
      layout-promotion side effects; cross-lane sharing on a treadmill;
      the Profile-switch reset; plain painting and Shift+drag ramp-edge
      editing both still work unchanged. Zero console errors throughout.
- [ ] **Idea for later: two-way highlight between the chart and the
      Preview textarea** – requested directly (hover a segment → its own
      text lights up below; move the caret in the text → the segment it
      falls in lights up on the chart), not yet built – design explored
      far enough to know the shape of it, parked here rather than rushed.
      Two real problems, independent of each other:
      1. **The Preview field is a plain `<textarea>`** – no native way to
         color part of its own text. `textarea.setSelectionRange(...)`
         is the tempting shortcut (native "highlight" for free, no new
         DOM), but it very likely only *renders* visibly while the
         textarea actually has focus – calling it on hover without
         focusing first (focusing on mere hover would be its own new
         problem, see below) would probably set the selection with
         nothing to show for it; this was flagged as a real risk but
         deliberately not empirically confirmed either way before
         stopping to write this note down instead of guessing further in
         code. The robust fallback (assume the worst) is the standard
         "poor man's syntax highlighting" trick: an invisible-background
         `<textarea>` layered exactly on top of a styled backdrop
         `<div>`/`<pre>` showing the identical text with the relevant
         range wrapped in a `<mark>` – same font/size/line-height/
         padding/border so the two stay pixel-aligned, backdrop's own
         `scrollTop`/`scrollLeft` synced from the textarea's `scroll`
         event, backdrop content regenerated alongside the textarea's
         own value on every edit (`handlePreviewEdit`/`updatePreview`
         both already touch `.value` at exactly the right moments to
         hook this into). More plumbing than `setSelectionRange`, but
         doesn't touch focus at all, so it can't ever fight the hover-
         driven chart interaction the previous entry just built (Cut/
         Mark/Delete's own keydown listener explicitly bails out the
         moment a text field has focus – *any* approach here has to
         leave that alone, hovering the chart must never silently steal
         focus into the textarea).
      2. **Export merges same-value neighbors into one run** – a
         segment-index-to-text-range map isn't 1:1: `ergLikeBodyFromSegments`
         and `buildZwo` both already collapse a run of identical
         consecutive segments into a single pair of `.erg`/`.mrc` lines
         or one `.zwo` block via `mergeRuns` (see those two functions'
         own doc comments). Highlighting "this segment's own text" for
         real means "the merged run it belongs to's own text" – both
         builders would need to track, per run, which segment index
         range (`r.start`…`r.start+r.length-1`) produced which *line*
         range of their own `lines` array (recording `lines.length`
         immediately before/after each run's own `push`(es), `pushZwoBlock`
         included since it can emit 1 or 3+ lines depending on whether
         the run carries a marker), then converting that to a character
         range once the full `lines` array is final (a small shared
         `lines.slice(0, n).join("\n").length`-based helper, not
         expensive at these array sizes). `buildErg`/`buildMrc` need one
         extra step `buildZwo` doesn't: shifting `ergLikeBodyFromSegments`'s
         own body-relative offsets by their own header's length, since
         that function's `lines` array is body-only, unlike `buildZwo`'s
         own single `lines` array spanning the whole file. And a real
         edge case to guard explicitly: `ergLikeBodyFromSegments` always
         reads `state.segments.bike`, never `activeSegments()` (.erg/.mrc
         are Power-only, see its own doc comment) – so the map it builds
         is only meaningful for cross-highlighting while `state.mode ===
         "bike"`; with the ".erg"/".mrc" tab active while Treadmill is
         the displayed Profile (both download cards are always shown,
         regardless of Profile), neither highlight direction should do
         anything at all, not highlight the wrong chart's segments.
- [x] **Fixed a real bug, reported directly: `docs/builder.html`'s `.zwo`
      export flattened every ramped Bike Power segment into one averaged
      flat value instead of an actual ramp.** This was previously
      believed to be a genuine `.zwo` format limitation (documented that
      way in several places this session) – turned out to be wrong.
      Verified directly against the file format reference (every
      attribute Zwift's own files have ever actually used, auto-
      generated from a large real-world corpus) before touching any
      code, specifically because getting the fix backwards would have
      been worse than the bug it fixes: `PowerLow`/`PowerHigh` really do
      exist, on `Warmup`/`SteadyState`/`Cooldown` alike, not just
      `Warmup`/`Cooldown` – and critically, they're **chronological**
      (start value / end value), not "whichever number happens to be
      smaller/larger" – confirmed by the reference's own worked example,
      a `Cooldown` ramping 100W down to 25W written as `PowerLow="1"
      PowerHigh="0.25"`, `PowerLow` there being the numerically *larger*
      one. `buildZwo`'s bike branch now writes a genuinely ramped
      segment (`seg0.startWatts !== lastSeg.endWatts` for its own merged
      run) as `PowerLow`/`PowerHigh` set to exactly that segment's own
      start/end values – no more averaging, no information lost at all
      – falling back to a plain `Power="…"` only for a truly flat run,
      same as before.
      Treadmill's own Speed/Incline ramps still always write the flat,
      averaged `Pace`/`Incline` pair too, alongside whichever of the new
      attributes below apply – re-checked the same reference just as
      carefully and confirmed Zwift's format has no `PaceLow`/`PaceHigh`/
      `InclineLow`/`InclineHigh` at all, anywhere, on any element, so
      that flat pair is the only thing any standard reader (Zwift, or
      this app's own *current* `ZWOWorkoutParser`) can actually use –
      never omitted, see the very next entry for what's added alongside
      it.
      Verified live in the browser: an ascending ramp (100W→200W)
      exported as `PowerLow="0.400" PowerHigh="0.800"`; a descending one
      (250W→100W) as `PowerLow="1.000" PowerHigh="0.400"` (confirming
      the direction survives, not just the two values); a workout mixing
      flat/ramped/flat segments showed the flat runs still correctly
      merging on either side while the ramp stayed its own unique block
      in between; a ramped `Warmup`-kind segment (via Shift+drag on the
      default sample) exported correctly as `<Warmup … PowerLow=…
      PowerHigh=…/>`, confirming the fix isn't SteadyState-only; the
      Treadmill branch re-confirmed still exporting a plain averaged
      `Pace`/`Incline` with no `Low`/`High` attributes at all, unaffected
      by the bike-side change. Zero console errors throughout.
- [ ] Also noted mid-conversation, not yet acted on: confirmed the
      user's own instinct that highlighting part of a plain `<textarea>`
      (see the two-way chart↔Preview highlight idea two entries up) is
      normally done with an overlay – the same technique a spell-checker
      uses for its own squiggly underlines.
- [x] **`docs/builder.html`: Treadmill Speed/Incline ramps now export via
      new, deliberately Unchain-specific `SpeedLow`/`SpeedHigh`/
      `InclineLow`/`InclineHigh` attributes** – requested directly, right
      after confirming Zwift's own format has no ramp attributes for
      Speed/Incline at all (previous entry). Since there's nowhere
      standard to put a real Treadmill ramp, this adds Unchain's own:
      written *alongside* the existing flat, averaged `Pace`/`Incline`
      pair, never instead of it (a reader that doesn't know these new
      attributes – every reader alive today, including this app's own
      `ZWOWorkoutParser` – just ignores them and keeps using the
      average, exactly as before this entry; this app's own future
      importer reading them back in is a deliberate, separate follow-up,
      deferred to `main`, not part of this). Each pair only appears when
      that specific field is actually ramped – `SpeedLow`/`SpeedHigh` and
      `InclineLow`/`InclineHigh` are independent (Speed and Incline can
      each ramp on their own within one segment, see the treadmill ramp-
      builder entry above), so a segment with only one of the two ramped
      only gets that one pair, not both.
      Verified live in the browser: a Speed-only ramp wrote `SpeedLow`/
      `SpeedHigh` with the flat `Pace` still present as their average and
      no `InclineLow`/`InclineHigh` at all; an Incline-only ramp the
      mirror image; both ramped on the same segment wrote all four
      attributes together, flat `Pace`/`Incline` still present too;
      confirmed the resulting `.zwo` still parses as well-formed XML
      (`DOMParser`); confirmed Bike's own export carries no
      `SpeedLow`/`InclineLow` at all, unaffected. Zero console errors.
- [ ] **Follow-up, deferred to `main` on purpose**: teach the app's own
      `ZWOWorkoutParser` (`Unchain/Models/TreadmillWorkoutProgram.swift`)
      to read `SpeedLow`/`SpeedHigh`/`InclineLow`/`InclineHigh` back in
      when present, producing a genuinely ramped `TreadmillWorkoutSegment`
      instead of just reading the flat `Pace`/`Incline` average it reads
      today. Not started – deliberately, per Oliver's own call: web-
      builder work now happens on its own `dev-workout-builder` branch,
      kept separate from the app (still developed on `main`), and this
      is squarely an app change.
- [x] **`docs/builder.html`: `.erg`/`.mrc` download cards are hidden
      entirely in Treadmill mode** – requested directly: those two are
      Power-only formats (`ergLikeBodyFromSegments` always reads
      `state.segments.bike`, never `activeSegments()`), so offering them
      at all while Treadmill is the displayed Profile was always an
      export disconnected from what's actually on screen – confirmed
      as unwanted rather than assumed. `renderAll` now toggles the two
      cards' own `#jack-erg`/`#jack-mrc` visibility off `state.mode`
      directly, and – the part that actually matters, since just hiding
      the card would still leave a stale erg/mrc `active-fmt` silently
      driving the Preview – force-switches `active-fmt` to `.zwo`
      whenever Treadmill is current and the active one was `erg`/`mrc`.
      Placed in `renderAll` itself rather than only the Profile toggle's
      own click handler, deliberately: every path that can change
      `state.mode` runs through it (pasting a Treadmill-shaped file or
      shorthand while on the erg/mrc tab, Undo/Redo landing back on a
      Treadmill state, a restored session booting straight into
      Treadmill), so all of them self-correct the same way, not just a
      deliberate Profile-toggle click.
      Verified live in the browser: switching to Treadmill hides both
      cards and switches the Preview to genuine `.zwo` content (label
      and text both); switching back to Bike brings both cards back,
      leaving `.zwo` active rather than silently reverting (no "remember
      what was active before" bookkeeping needed – the rider can just
      click `.erg` again); pasting Treadmill shorthand while `.erg` was
      active auto-switched Profile *and* correctly hid the card/forced
      `.zwo` *without* touching the Preview textarea's own just-pasted
      content (matches `handlePreviewEdit`'s existing "never overwrite a
      still-being-edited paste" rule); Undo back to Bike correctly
      un-hides the cards, Redo back to Treadmill correctly re-hides them.
      Zero console errors throughout.
- [x] **Corrected: a ramped Treadmill segment now exports as its own
      `<Ramp>` block, not as `SpeedLow`/`SpeedHigh`/`InclineLow`/
      `InclineHigh` attributes bolted onto `Warmup`/`SteadyState`/
      `Cooldown`** – the previous entry above got this wrong: those four
      attribute names were invented specifically *for* a `<Ramp>` block,
      deliberately mirroring how Zwift's own real `<Ramp>` element
      carries `PowerLow`/`PowerHigh` for cycling, not as a generic
      "ramping" suffix to sprinkle onto any block. `buildZwo`'s treadmill
      branch now writes `<Ramp Duration=… SpeedLow=… SpeedHigh=…
      InclineLow=… InclineHigh=…/>` for an actually-ramped segment (all
      four attributes always together, `Low === High` for whichever
      dimension isn't ramping – a `<Ramp>` block has no flat `Pace`/
      `Incline` fallback of its own the way `Warmup`/`SteadyState`/
      `Cooldown` do), and keeps writing plain `Warmup`/`SteadyState`/
      `Cooldown` with flat `Pace`/`Incline` for a genuinely flat segment,
      exactly as before this correction. A ramped segment's own `kind`
      is deliberately not preserved in the file any more – same as
      Zwift's own `<Ramp>`, which isn't tagged Warmup/SteadyState/
      Cooldown either.
      `applyZwoText` (this tool's own `.zwo` import, used for re-loading
      an exported file, drag & drop, and pasting into the Preview) now
      also accepts `<Ramp>` in its block whitelist and reads `SpeedLow`/
      `SpeedHigh`/`InclineLow`/`InclineHigh` (new `clampToStep` helper,
      factored out of the clamp-then-round-to-step dance the flat
      Pace/Incline/Power reads already did inline) – without this, a
      self-exported ramped segment would have silently vanished on
      re-import instead of round-tripping, a real regression this
      correction would otherwise have introduced. A genuine cycling
      `<Ramp>` (Power-based, no Speed/Incline attributes) still imports
      without crashing – falls back to `lanes.speed.min`/`lanes.incline
      .min`, the same graceful-fallback treatment any block missing
      `Pace`/`Incline` already got.
      Verified live in the browser: pasted a hand-written `<Ramp
      Duration="60" SpeedLow="4.0" SpeedHigh="6.0" InclineLow="2.0"
      InclineHigh="7.0"/>` between a flat Warmup and Cooldown – chart
      showed the correct ramp shape immediately; toggling Profile away
      and back (forces a full re-render from the preserved `state
      .segments.treadmill`) re-exported byte-for-byte the same `<Ramp>`
      line, with the flat Warmup/Cooldown blocks carrying plain
      `Pace`/`Incline` and no stray `SpeedLow`/`InclineLow` at all;
      pasting a Power-based `<Ramp>` (no Speed/Incline attributes)
      produced no console error and fell back to flat zeros as expected.
      Zero console errors throughout. Also updated the app-side
      `ZWOWorkoutParser` (`main`) to match this corrected design – see
      its own `STATUS.md` entry there.
