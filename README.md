<img src="Bahoo/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="96" align="right" alt="Bahoo app icon">

# Bahoo

Lean iOS app for controlling smart trainers (Kickr & co.) via the open
**FTMS** Bluetooth standard (Fitness Machine Service) — not a Wahoo-proprietary
protocol, so it works in principle with any FTMS-capable trainer.

## Status (MVP, Phase 1)

- [x] BLE scan for FTMS devices
- [x] Establish connection, request control (`Request Control`)
- [x] Live display: power, cadence, speed
- [x] Manual control via +/− buttons, switchable between **power (watts)** and
      **resistance (%)**
- [x] Automatic clamping to the value range reported by the device
- [x] Screen stays awake as long as the app is active in the foreground (no
      background operation, as intended)
- [x] Pairing with a heart rate strap via the open Bluetooth SIG standard
      **Heart Rate Service** (0x180D) — runs in parallel to the trainer
      connection, so it works with virtually any BLE strap (Polar, Garmin,
      Wahoo TICKR, …), not just vendor-specific devices
- [x] Start/Pause/Stop workout controls, sent to the trainer's FTMS control
      point. Automatically detects whether the connected FTMS device is a
      bike or a treadmill (Indoor Bike Data vs. Treadmill Data characteristic).
      After stopping, offers to save the session to Apple Health — as
      **Indoor Cycling** for a bike, or a choice between **Indoor Walk** and
      **Indoor Run** for a treadmill (FTMS itself can't tell those apart).
      Elapsed time is pause-aware; distance is a rough estimate integrated
      from live speed (no dedicated energy/calorie tracking yet)
- [ ] Import of workout files (e.g. `.erg`/`.mrc` or CSV) for automated
      workouts — planned for phase 2

Deployment target: **iOS 16.0** · Target device: **iPhone XS** (max. iOS 18 on
this model) · iPhone only (no iPad layout).

## Generating the project

The Xcode project itself isn't kept in the repo; it's generated from
[`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the usual way to avoid `.xcodeproj` merge conflicts).

```bash
brew install xcodegen
cd /Users/olau/Workspace/bahoo-kickass
xcodegen generate
open Bahoo.xcodeproj
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

For phase 2 (automated workouts) you need ready-made `.erg`/`.mrc` files. Most
providers require an account for that – one exception:

- **[cyclingintervals.com](https://cyclingintervals.com/)** — free structured
  workouts available directly as `.erg`, `.mrc`, `.zwo`, or `.fit` downloads,
  **no registration/login** required.
- [trainerday.com](https://trainerday.com) (formerly ErgDB) — very large
  library, but downloads usually require login.

## Running

Bluetooth doesn't work in the simulator — the app must run on a real iPhone
(your iPhone XS is directly suitable for this).

## Next steps (Phase 2)

- Parser for `.erg`/`.mrc` files (time → target watts or %FTP), alternatively/
  additionally CSV. Advantage of `.erg`: there are many free workouts available
  online in this format.
- Playback engine: a timer that automatically sends target values from the
  loaded file to `TrainerConnection.setTargetPower`/`setTargetResistancePercent`.
- Progress display (elapsed time, current interval, remaining time).
