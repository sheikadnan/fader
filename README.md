# Fader

**Per-app volume for macOS.** Spotify at 30%, Zoom at full volume, no compromise.

Fader lives in the menu bar and gives every app its own volume slider and mute
button. Nothing is recorded, nothing leaves your Mac, and when you are not
adjusting anything Fader is not in your audio path at all.

```
 30%   Spotify        ─────●───────────
 100%  Zoom           ────────────────●
 mute  Safari         ────────────────●
```

## Requirements

- macOS 14.2 or later (Core Audio Process Taps were introduced in 14.2)
- Apple silicon or Intel
- To build: Xcode **or** the Command Line Tools with Swift 6

## Install

### Download

Grab `Fader.app` from the [latest release](../../releases/latest), move it to
`/Applications`, and open it. Fader appears in the menu bar as a sliders icon.

Because the app is not notarized, the first launch needs **System Settings ›
Privacy & Security › Open Anyway**, or:

```sh
xattr -d com.apple.quarantine /Applications/Fader.app
```

### Build from source

```sh
git clone https://github.com/sheikadnan/fader.git
cd fader
make app        # produces ./Fader.app
make run        # builds and opens it
```

`make test` runs the test suite.

## Using it

Click the menu bar icon. Every app currently making sound is listed with a
slider and a mute button.

- **Adjust a slider** and that app's volume changes immediately.
- **Mute** silences one app without touching anything else.
- **Right-click a row** to pin an app to the top of the list, or reset it.
- **"All" toggle** shows every audio process on the machine, not just the ones
  playing.

Settings are stored per app and survive relaunches. The first time you move a
slider, macOS asks for permission to read audio — see below.

## Permissions

Applying a volume to another app's audio requires reading that app's audio
first. Fader uses a **Core Audio process tap**, which is the system's
purpose-built mechanism for exactly this.

- Audio is processed in memory as it plays. It is never written to disk, and
  Fader has no networking code.
- The tap is created with `muteBehavior = .mutedWhenTapped`, so the original app
  is silenced *only while Fader is actively reading it*. If Fader crashes, is
  force-quit, or is uninstalled, the tap dies with it and every app returns to
  full volume immediately. There is no state left behind to get stuck.
- If you deny the permission, Fader still runs and lists apps, but changes
  nothing.

If volume changes have no effect, open the probe (below) and check the reported
tap status.

## How it works

macOS has no "set this app's volume" API. What it has, since 14.2, is a process
tap: permission to read one process's audio, plus the ability to mute the
original while it is being read. Volume then becomes a multiplication you
perform yourself.

```
  [Spotify]──▶ normal system path ──▶ (silenced while tapped)
                     │
          CATapDescription(processes: [spotify],
                           muteBehavior: .mutedWhenTapped)
                     ▼
              Process Tap
                     ▼
   private aggregate device { taps: […], subdevice: [default output] }
                     ▼
   one render callback: per-app gain ─▶ sum ─▶ hardware
```

The design turns on three properties:

1. **`.mutedWhenTapped` is fail-safe.** The mute exists only while the tap
   exists, and the tap dies with the process. If Fader is force-quit, audio
   returns on its own. No cleanup needed, nothing to get stuck.
2. **One aggregate device on the output device's clock.** Input and output share
   a clock domain, so there are no ring buffers, no resampling, and no drift
   compensation in the mixer. The added latency is one buffer.
3. **Passthrough means no tap at all.** An app at 100% and unmuted is never
   touched. When nothing is adjusted, Fader holds no taps and does no work.

### Layout

```
Sources/FaderCore/          everything that is not UI
  HAL.swift                 typed Core Audio property wrappers
  ProcessCatalog.swift      HAL process list + change notifications
  AudioDevices.swift        default output device, formats, liveness
  MixerEngine.swift         tap and aggregate lifetime, gain fast path
  MixerRenderer.swift       the real-time render callback
  StreamLayout.swift        maps aggregate channels back to taps (pure)
  GainRamp.swift            click-free gain smoothing (pure)
  MixerStore.swift          single source of truth for the UI
  SettingsStore.swift       JSON persistence
Sources/Fader/              menu bar app (AppKit + SwiftUI)
Sources/FaderProbe/         diagnostic CLI, see "Troubleshooting"
```

`MixerStore` is the only thing the UI talks to. `ProcessCatalog` and
`MixerEngine` know nothing about each other; `MixerStore` joins them.

### Real-time rules

The render callback allocates nothing, takes no locks, logs nothing, and
messages no objects. All state is preallocated and indexed by a plan built once
when the graph is created.

## Verification status

What is proven, and how:

- **Verified on hardware.** The probe taps a playing app and mixes it, and
  measures the result rather than trusting it. On the built-in speakers with a
  0.05-amplitude tone requested at 50%:

  | measured | value |
  | --- | --- |
  | input peak | 0.05002 |
  | output peak | 0.02501 |
  | output / input (RMS) | 0.500 |
  | added latency | one buffer (≈10.7 ms at 48 kHz) |

- **Verified by test.** 24 tests cover gain ramping, channel-to-tap mapping,
  identity across process restarts, and settings persistence including corrupt
  and older files.
- **Not yet verified by ear.** That `mutedWhenTapped` silences the original app
  in the speaker path is documented behaviour and the arithmetic is right, but
  confirming the original does not double up needs a human. Run
  `fader-probe --run` with music playing and listen.
- **Not yet verified on other hardware.** Bluetooth, USB interfaces, and
  multi-channel devices have not been exercised.

## Troubleshooting

```sh
swift run fader-probe            # report devices, processes, tap + layout
swift run fader-probe --run      # mix everything audible at 50% for 6 s, then restore
```

The probe changes nothing unless you pass `--run`, and it always destroys its
taps on the way out. It reports the raw `OSStatus` of every step, so a failed
tap says why.

### An app is missing from the list

Fader lists what is *playing*. Apps are identified by the app you launched, not
by the helper process that does the decoding — Chrome playing YouTube shows as
**Google Chrome**, not `Google Chrome Helper`, and one volume setting covers all
of its processes.

To see exactly what Fader built, and why:

```sh
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.fader.app"' | grep "rows"
swift run fader-probe --watch    # live view of every process the HAL reports
```

### The menu bar icon

Fader has no Dock icon and no window, so the menu bar item is the whole user
interface. It sits on the right-hand side of the menu bar and looks like three
vertical sliders. If you cannot see it:

- Check the app is running: `pgrep -x Fader`
- Menu bar space is finite, and macOS hides overflow items silently. Quit
  something else from the menu bar and it will reappear.
- Ask the app where it put the item:

  ```sh
  /usr/bin/log show --last 5m --info --predicate 'subsystem == "com.fader.app"' | grep "status item"
  ```

  That prints the item's frame and whether it is visible on screen.

Known limitations:

- **Apps routed to a non-default output device are left alone.** Fader mixes
  into the default output. It will not silently reroute an app that you sent to
  your headphones.
- **Volume is capped at 100%.** Fader never boosts, so nothing ever clips.
- **DRM-protected audio** (some Apple Music and streaming content) may be silent
  through a tap. This is a platform restriction.

## Contributing

Issues and pull requests are welcome. Please run `make test` before opening a
PR, and keep the real-time rules above intact.

## License

MIT — see [LICENSE](LICENSE).
