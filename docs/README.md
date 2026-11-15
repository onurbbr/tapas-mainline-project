# Tapas — documentation

Xiaomi Redmi Note 12 4G (codename **tapas**, SoC **SM6225 "Khaje"**) running
mainline Linux.

One document per subsystem, all of them directly in this directory. Each opens
with a `**Status:**` line that states how far it got, so a file name never
hides a partial result: proximity produces readings but never reports `NEAR`,
the camera captures RAW frames but has no ISP, and both say so on their first
line rather than being filed under a heading that lies about them.

Everything here was measured on hardware unless a section says otherwise. No
claim is made for anything that was not actually exercised.

- [Project status](status.md) — kernel trees, packaging, and a longer summary
- [`../sources/forensics/`](../sources/forensics/) — vendor device trees,
  decompiled, kept as reference

## At a glance

| Subsystem | Status | Detail |
|---|---|---|
| Boot | Working — U-Boot from SD card, Debian, slot A keeps Android | [status](status.md) |
| Display | Working — Xiaomi M7 38 0C 0A AMOLED, 1080x2400 DSI | [status](status.md) |
| Touch | Working — Focaltech FT3518/FT3519 | [status](status.md) |
| Storage | Working — UFS and the QMP UFS PHY | [status](status.md) |
| Charging | Working — BQ25890 with USB type reporting, SC8551, SM5602, DS28E16 | [status](status.md) |
| Audio playback | Working — speaker, headphones on jack, earpiece | [audio](audio.md) |
| Audio capture | Working — handset and top microphone together, headset boom on jack | [audio](audio.md) |
| Third microphone (ADC3 / AMIC4) | Untested — wired in the device tree, never exercised | [audio](audio.md) |
| Haptics | Working — on/off only, the enable GPIO is the single control | [status](status.md) |
| Sensors | Working — accelerometer, ambient light, compass | [status](status.md) |
| Camera capture | Working, RAW only — rear main, front, ultra wide | [camera](camera.md) |
| Camera lens | Working in the kernel — `focus_absolute` moves the voice coil | [camera](camera.md) |
| ISP / 3A | Missing — no mainline ISP, so cameras deliver RAW Bayer | [camera](camera.md) |
| Video decode | Working — H.264, HEVC and VP9 through `iris` | [video decode](video-decode.md) |
| Proximity | Partial — readings arrive, `NEAR` never triggers | [proximity](proximity.md) |
| Autofocus | Open in userspace — kernel side done, no AF above it | [autofocus](autofocus.md) |
| Rear macro camera | Open — the sensor probes, no frames arrive | [macro camera](camera-macro.md) |
| Voice call | Parked — the DSP rejects the voice graph | [voice call](voice-call.md) |

## The documents

| File | Covers |
|---|---|
| [status.md](status.md) | Kernel trees, what is installed, packaging, firmware and calibration data |
| [audio.md](audio.md) | Playback and capture paths, mixer controls, the headset microphone, the bugs that had to be fixed |
| [camera.md](camera.md) | Four modules, the CSIPHY/CSID/VFE pipeline, the PLL problem, the accessories (voice coil, EEPROM, flash LED) |
| [video-decode.md](video-decode.md) | Why `iris` and not `venus`, the three fixes it needed, measured decode results |
| [proximity.md](proximity.md) | The boot race that hid the sensor, and why the raw range cannot be thresholded |
| [autofocus.md](autofocus.md) | The GT9764 actuator, the working kernel control, and the missing userspace stack |
| [camera-macro.md](camera-macro.md) | The GC02M1 that probes but never streams, and the eleven hypotheses already ruled out |
| [voice-call.md](voice-call.md) | Why call audio does not go through this card, and where the AudioReach work stopped |

## Git repositories

| What | Where |
|---|---|
| Kernel, current tree | `sm6225-tapas` branch of [sm6225-mainline/kernels/linux](https://gitlab.nura.eco/sm6225-mainline/kernels/linux), based on Linux v7.4-rc1 |
| Kernel, previous tree | `sm6225` branch of [onurbbr/linux](https://github.com/onurbbr/linux), based on Linux v7.3 |
| Everything else | this repository |

The 7.4 tree is the one to work on from now on. The 7.3 tree stays as it is,
frozen at the point where it was left, and is only of historical interest.
