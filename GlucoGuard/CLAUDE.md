# GlucoGuard — Project Instructions

## Project

Garmin Connect IQ Watch App written in Monkey C (GlucoGuard). It's a full-screen
Watch App — not a widget, data field, or watch face — built around a
user-initiated "Start Snapshot" flow: a fixed ~4-minute foreground capture that
produces one risk score per snapshot.

There is no background execution anywhere in this app — no
`Toybox.Background`, `registerForTemporalEvent`, or `ServiceDelegate`. If the
app closes, nothing continues running; the user has to reopen it and start
fresh.

## Toolchain

Connect IQ SDK + Monkey C VS Code extension (monkeyc/monkeydo). Standard
structure: `manifest.xml`, `monkey.jungle`, `/source/*.mc`, `/resources/...`.
Targets API level 3.0.0+ (required for raw beat-to-beat sensor data).

## Language caveats (Monkey C)

Monkey C is a low-training-data language for the model, so API names should be
verified, not guessed.

- Imports use `using Toybox.X as Y;`
- Strict typing is opt-in per file/project — don't mix typed and untyped
  styles without saying so.
- Sensor/storage reads return `null` constantly and must be null-checked.
- Hardware-dependent calls need `has` capability checks (e.g.
  `Attention has :vibrate`).
- Symbols (`:foo`) must never be used as Storage keys/values.
- One binary = one shell type (Watch App/Widget/Watch Face/Data Field) — no
  combining.

## Key APIs in use

- **Live HR**: `Sensor.getInfo().heartRate`
- **Historical HR/stress/body battery/SpO2**:
  `Toybox.SensorHistory.get*History({:period, :order})` → iterator with
  `.data`/`.when`
- **Raw beat-to-beat + accelerometer**: a single combined
  `Sensor.registerSensorDataListener()` call (only one can be active
  app-wide) requesting both `:heartBeatIntervals` and `:accelerometer`
  together — callback gives `.heartRateData.heartBeatIntervals` and
  `.accelerometerData.power`. Requires Sensor permission. Simulator returns
  fake constant HR intervals — HRV results are only trustworthy on a
  physical watch.
- **Storage**: `Application.Storage.setValue/getValue`, 32KB/value cap, used
  to store a capped history of completed snapshot results (for baseline +
  future relabeling), not live buffers.
- **Risk-score weights**: no published "correct" weights exist for this
  formula shape — start equal, refit only from this project's own labeled
  data. Don't invent coefficients or cite outside studies.
- **Alerts**: `Attention.vibrate()` / `Attention.playTone()`, both
  has-guarded.
- **Explicitly unavailable**: no respiration-rate API, no built-in HRV call
  (must compute RMSSD from raw intervals).

## Working style for whoever codes this

- Implement only the specific step requested, don't get ahead of the spec.
- After each change, state what's testable in the simulator vs. what needs
  the physical watch (HRV/raw sensor always needs hardware).
- Show diffs against existing files, not full rewrites, and name every file
  touched.
- Always caveat that this is not a diagnostic/medical device.
