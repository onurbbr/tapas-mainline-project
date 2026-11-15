# Tapas — documentation

Xiaomi Redmi Note 12 4G (codename **tapas**, SoC **SM6225 "Khaje"**) running
mainline Linux.

This directory is split in two: what runs on the device today, and what does
not. Everything here was measured on hardware unless a section says otherwise;
no claim is made for anything that was not actually exercised.

- [Project status](status.md) — kernel trees, packages, and the full picture
- `working/` — subsystems that are usable
- `not-working/` — open problems, with the measurements behind them
- `../sources/forensics/` — vendor device trees, decompiled, used as reference

## Working

| Subsystem | What works | Detail |
|---|---|---|
| Boot | U-Boot from SD card, Debian userspace, slot A keeps Android | [status](status.md) |
| Display | Xiaomi M7 38 0C 0A AMOLED, 1080x2400 DSI | [status](status.md) |
| Touch | Focaltech FT3518/FT3519 over I2C | [status](status.md) |
| Storage | UFS, QMP UFS PHY | [status](status.md) |
| Audio playback | Speaker, headphones with automatic jack switch, earpiece | [audio](working/audio.md) |
| Audio capture | Handset microphone and top microphone together; headset boom microphone when a cable is plugged in | [audio](working/audio.md) |
| Haptics | Vibration motor, on/off only | [status](status.md) |
| Sensors | Accelerometer, ambient light, compass | [status](status.md) |
| Camera capture | Rear main (S5KJN1), front (S5K3L6), rear ultra wide (OV08D10) as RAW Bayer | [camera](working/camera.md) |
| Camera lens | V4L2 `focus_absolute`, the voice coil actually moves | [camera](working/camera.md) |
| Video decode | H.264, HEVC and VP9 through `iris` | [video decode](working/video-decode.md) |
| Charging | BQ25890 with USB charger type reporting, SC8551, SM5602, DS28E16 | [status](status.md) |

## Not working

| Subsystem | Problem | Detail |
|---|---|---|
| Voice call | No call audio in either direction. Parked. | [voice call](not-working/voice-call.md) |
| Proximity | The sensor is published but never reports `NEAR` | [proximity](not-working/proximity.md) |
| Rear macro camera | The sensor probes, no frames arrive | [macro camera](not-working/camera-macro.md) |
| Autofocus | The kernel side works, no userspace stack drives it | [autofocus](not-working/autofocus.md) |
| ISP / 3A | No mainline ISP, so cameras deliver RAW Bayer only | [camera](working/camera.md) |
| Third microphone input | ADC3 / AMIC4 is wired in the device tree but was never tested | [audio](working/audio.md) |

## Git repositories

| What | Where |
|---|---|
| Kernel, current tree | `sm6225-tapas` branch of [sm6225-mainline/kernels/linux](https://gitlab.nura.eco/sm6225-mainline/kernels/linux), based on Linux v7.4-rc1 |
| Kernel, previous tree | `sm6225` branch of [onurbbr/linux](https://github.com/onurbbr/linux), based on Linux v7.3 |
| Everything else | this repository |

The 7.4 tree is the one to work on from now on. The 7.3 tree stays as it is,
frozen at the point where it was left, and is only of historical interest.
