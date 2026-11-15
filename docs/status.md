# Tapas — project status

Xiaomi Redmi Note 12 4G (tapas / SM6225) mainline port.

This is the summary. Each topic has a document of its own with the
measurements, the things that were ruled out and the commands used; the
**Detail** column of every table below points at it.

## Kernel trees

| Tree | Branch | Base | Commits | State |
|---|---|---|---|---|
| `Kernels/linux-7.4` | `sm6225-tapas` | Linux v7.4-rc1 | 82 | **current** — pushed to [gitlab.nura.eco](https://gitlab.nura.eco/sm6225-mainline/kernels/linux/-/tree/sm6225-tapas) |
| `Kernels/linux-7.3` | `sm6225` | Linux v7.3 | 104 | frozen — pushed to `github.com:onurbbr/linux` |

The 7.4 tree is where development continues. The 7.3 tree is kept for
reference only; nothing new lands there.

- Installed on the device at the time of writing: `7.3.0-sm6225-upstream+`;
  the 7.4 tree builds cleanly but a 7.4 image was not installed yet
- Distribution: Debian, booting from SD card (Android occupies the other boot
  slot)
- Packaging: `scripts/build-debs.sh` in this repository

---

## What works

| Subsystem | Notes | Detail |
|---|---|---|
| Boot and storage | U-Boot, Debian from SD card, UFS | — |
| Display | Xiaomi M7 38 0C 0A AMOLED, 1080x2400 | — |
| Touch | Focaltech FT3518/FT3519, `edt-ft5x06` | — |
| Charging | BQ25890 (USB type reporting), SC8551, SM5602, DS28E16 | — |
| Audio playback | Speaker, headphones with automatic switch, earpiece | [audio.md](audio.md) |
| Audio capture | Handset + top microphone together, headset boom microphone on jack | [audio.md](audio.md) |
| Haptics | On/off only; the enable GPIO is the single control | — |
| Sensors | Accelerometer, ambient light, compass | — |
| Camera capture | Rear main, front and rear ultra wide, RAW Bayer | [camera.md](camera.md) |
| Camera lens | V4L2 `focus_absolute` moves the voice coil | [camera.md](camera.md) |
| Video decode | H.264, HEVC, VP9 through `iris` | [video-decode.md](video-decode.md) |

## What does not work, or only partly works

| Subsystem | State | Blocker | Detail |
|---|---|---|---|
| Proximity | Partial | Raw `distance` from the DSP sits in 12–17, thresholds are 95/50 | [proximity.md](proximity.md) |
| ISP / 3A | Missing | There is no mainline ISP for this SoC | [camera.md](camera.md) |
| Autofocus | Open | No AF algorithm in the libcamera software ISP | [autofocus.md](autofocus.md) |
| Rear macro camera | Open | The sensor probes, no frames arrive | [camera-macro.md](camera-macro.md) |
| Third microphone | Untested | ADC3 / AMIC4, wired but never exercised | [audio.md](audio.md) |
| Voice call | Parked | The DSP rejects `GRAPH_PREPARE` on the voice graph | [voice-call.md](voice-call.md) |

None of these are regressions; they were either out of scope for the port or
have no mainline counterpart yet.

---

## 1. Audio

Playback and capture both work, including the jack switch. The paths, the
control names and the bugs that had to be fixed are in [audio.md](audio.md).

The one exception is call audio, which does not go through this card at all.
That is a separate problem, recorded in [voice-call.md](voice-call.md).

## 2. Camera

Three of the four modules capture frames. The fourth probes but delivers
nothing. The full detail — the accessory list (voice coil, EEPROM, flash LED),
the CSIPHY/CSID/VFE pipeline and the PLL problem that blocked it — is in
[camera.md](camera.md); the macro module has its own document,
[camera-macro.md](camera-macro.md).

Colour is handled in userspace from vendor tuning converted with
`tools/go-chromatix2libcamera`. Only `BlackLevel`, `Awb`, `Ccm`, `Adjust` and
`Agc` load in libcamera 0.7.2; `Lsc`, `Denoise`, `Sharpen` and `Af` make the
software IPA fail to initialise.

## 3. Video decode

Hardware decode works end to end through `iris`, see
[video-decode.md](video-decode.md). The vendor firmware speaks HFI generation
2, which `venus` cannot drive; `iris` detects the generation from the image
itself, and needed three fixes before it would come up on this SoC.

## 4. Haptics

Binary on/off. The PM6125 GPIO 8 is the only control, both in the vendor
driver and in `gpio-vibrator`, so there is no amplitude modulation to port.
Feel is tuned through feedbackd's vibration patterns instead.

## 5. Sensors

Accelerometer, ambient light and compass arrive over the Snapdragon Sensor
Core stack (`hexagonrpcd` plus `iio-sensor-proxy`), not through kernel sensor
drivers — the physical drivers live inside the ADSP firmware. Proximity is
published by the same path but never reports `NEAR`; see
[proximity.md](proximity.md) for the measurements.

---

## Firmware and calibration data

`staging/firmware/` contains blobs extracted from the device's own vendor
partition (ADSP/CDSP/modem firmware, DSP libraries, ACDB calibration
databases, SSC registry). They are redistributed here only to make this
specific device work, and remain the property of their respective owners.

## Vendor reference material

`sources/forensics/` holds the vendor device trees decompiled once from
`images/` — the merged Tapas DT, the Tapas overlay and the base SoC tree —
together with the script that produces them. See
[`../sources/forensics/README.md`](../sources/forensics/README.md).
