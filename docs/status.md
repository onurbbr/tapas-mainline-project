# Tapas — project status

Xiaomi Redmi Note 12 4G (tapas / SM6225) mainline port.

## Kernel trees

| Tree | Branch | Base | Commits | State |
|---|---|---|---|---|
| `Kernels/linux-7.4` | `sm6225-tapas` | Linux v7.4-rc1 | 82 | **current** — pushed to `gitlab.nura.eco` |
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

| Subsystem | Notes |
|---|---|
| Boot and storage | U-Boot, Debian from SD card, UFS |
| Display | Xiaomi M7 38 0C 0A AMOLED, 1080x2400 |
| Touch | Focaltech FT3518/FT3519, `edt-ft5x06` |
| Audio playback | Speaker, headphones with automatic switch, earpiece |
| Audio capture | Handset + top microphone together, headset boom microphone on jack |
| Haptics | On/off only; the enable GPIO is the single control |
| Sensors | Accelerometer, ambient light, compass |
| Camera capture | Rear main, front and rear ultra wide, RAW Bayer |
| Camera lens | V4L2 `focus_absolute` moves the voice coil |
| Video decode | H.264, HEVC, VP9 through `iris` |
| Charging | BQ25890 (USB type reporting), SC8551, SM5602, DS28E16 |

## What does not work

| Subsystem | Blocker | Detail |
|---|---|---|
| Voice call | The DSP rejects `GRAPH_PREPARE` on the voice graph | [`not-working/voice-call.md`](not-working/voice-call.md) |
| Proximity | Raw `distance` from the DSP sits in 12–17, thresholds are 95/50 | [`not-working/proximity.md`](not-working/proximity.md) |
| Rear macro camera | The sensor probes, no frames arrive | [`not-working/camera-macro.md`](not-working/camera-macro.md) |
| Autofocus | No AF algorithm in the libcamera software ISP | [`not-working/autofocus.md`](not-working/autofocus.md) |
| ISP / 3A | There is no mainline ISP for this SoC | [`working/camera.md`](working/camera.md) |
| Third microphone | ADC3 / AMIC4, wired but never tested | [`working/audio.md`](working/audio.md) |

None of these are regressions; they were either out of scope for the port or
have no mainline counterpart yet.

---

## 1. Audio

Playback and capture both work, including the jack switch. The paths, the
control names and the four bugs that had to be fixed are in
[`working/audio.md`](working/audio.md).

The one exception is call audio, which is a separate problem: it does not go
through this card at all. See
[`not-working/voice-call.md`](not-working/voice-call.md).

## 2. Camera

Three of the four modules capture frames. The fourth probes but delivers
nothing. Full detail, the accessory list (voice coil, EEPROM, flash LED) and
the pipeline are in [`working/camera.md`](working/camera.md); the macro
module has its own document, [`not-working/camera-macro.md`](not-working/camera-macro.md).

Colour is handled in userspace from vendor tuning converted with
`tools/go-chromatix2libcamera`. Only `BlackLevel`, `Awb`, `Ccm`, `Adjust` and
`Agc` load in libcamera 0.7.2; `Lsc`, `Denoise`, `Sharpen` and `Af` make the
software IPA fail to initialise.

## 3. Video decode

Hardware decode works end to end through `iris`, see
[`working/video-decode.md`](working/video-decode.md). The vendor firmware
speaks HFI generation 2, which `venus` cannot drive; `iris` detects the
generation from the image itself.

## 4. Haptics

Binary on/off. The PM6125 GPIO 8 is the only control, both in the vendor
driver and in `gpio-vibrator`, so there is no amplitude modulation to port.
Feel is tuned through feedbackd's vibration patterns instead.

---

## Firmware and calibration data

`staging/firmware/` contains blobs extracted from the device's own vendor
partition (ADSP/CDSP/modem firmware, DSP libraries, ACDB calibration
databases, SSC registry). They are redistributed here only to make this
specific device work, and remain the property of their respective owners.
