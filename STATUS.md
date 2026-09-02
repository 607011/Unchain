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
