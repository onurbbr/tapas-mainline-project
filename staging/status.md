# Tapas — project status

Xiaomi Redmi Note 12 4G (tapas / SM6225) mainline port.

- Kernel branch: `sm6225`, based on `c03c1a14507d` (Linux v7.3), 104 commits
- Prepared for 7.4: branch `sm6225-tapas` under `Kernels/linux-7.4`, based on
  7.4-rc1, 81 commits, pushed to `gitlab.nura.eco`; it stays parked until 7.4
  stabilises
- Running kernel on device: `7.3.0-sm6225-upstream+`
- Distribution: Debian, booting from SD card (Android on the other boot slot)

Per-topic details, measurements and dead ends live in `issues/`.

---

## Open topics

| # | Topic | Status | Blocker | Size | File |
|---|-------|--------|---------|------|------|
| 1 | Microphone (capture) | **WORKING** — handset + top microphone together, headset microphone on jack | Third microphone input (ADC3) untested | Small | `issues/microphone.md` |
| 2 | Proximity sensor | **PARTIAL** — visible, never changes state | Raw `distance` reported by the DSP is in the 12–17 range; thresholds are 95/50 | Medium, uncertain | `issues/proximity.md` |
| 3 | Camera | **PARTIAL** — rear main, front and ultra wide capture RAW frames | Macro sensor driver does not produce frames; no ISP/3A; no autofocus in userspace; RDI is frame based | Large | `issues/camera.md` |
| 4 | Video decode | **WORKING** — H.264, HEVC and VP9 through `iris` | none | — | this file |
| 5 | Voice call | **PARKED** — no call audio | The DSP rejects `GRAPH_PREPARE` on the voice graph; the work is archived in `sources/tapas-voice-poc/` | Large | `issues/voice-call.md` |

None of these are regressions. They were either deliberately out of scope for the
initial port or have no mainline counterpart yet.

---

## 1. Microphone

Both internal microphones and the headset boom microphone **work**. They are
never active at the same time: without a cable the two internal ones capture
together (one per channel), and plugging a headset with a microphone replaces
them with the boom microphone.

Handset + top path, no cable plugged in:

```
AMIC1 -> ADC1 -> ADC1_OUTPUT --SoundWire--> TX SWR_INPUT0
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC0)
      -> TX_AIF1_CAP Mixer DEC0 -> hw:0,3 left channel

AMIC3 -> ADC2 MUX (INP3) -> ADC2 -> ADC2_OUTPUT --SoundWire--> TX SWR_INPUT4
      -> TX DEC1 MUX (SWR_MIC) -> TX SMIC MUX1 (SWR_MIC4)
      -> TX_AIF1_CAP Mixer DEC1 -> hw:0,3 right channel
```

Headset path:

```
AMIC2 -> ADC2 MUX (INP2) -> ADC2 -> ADC2_OUTPUT --SoundWire--> TX SWR_INPUT4
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC4)
      -> TX DEC1 MUX (SWR_MIC) -> TX SMIC MUX1 (SWR_MIC4)
      -> TX_AIF1_CAP Mixer DEC0 + DEC1 -> hw:0,3 both channels
```

Which ADC2 input is used is decided by `ADC2 MUX`: `INP3` is the top
microphone, `INP2` is the headset boom microphone. The slot number is
`SWR_MICn = (master_port - 1) * 4 + (channel - 1)`; ADC1 is on master port 1
channel 1 (`SWR_MIC0`) and ADC2 on master port 2 channel 1 (`SWR_MIC4`).
Earlier attempts used `SWR_MIC1`, where nothing is transmitted, which is why
ADC2 looked dead for several sessions while the vendor stack (which configures
channel 2 and therefore reads `SWR_MIC5`) worked.

Measured with no cable plugged in:

| test | left (ADC1) | right (ADC2 / INP3) | correlation |
|---|---|---|---|
| room noise, `arecord -D hw:0,3` | rms 73.7 | rms 58.5 | 0.167 |
| tapping the top edge microphone | rms 48.8 | rms 11285.1 | -0.018 |
| `pw-record` through the UCM source | rms 65.1 | rms 30.5 | 0.176 |

The boom microphone is a single ADC, so both decimators are fed from the same
SoundWire slot and the stereo PCM carries it on both channels (correlation
0.9986).

Six real bugs were fixed along the way:
Six real bugs were fixed along the way:

1. The UCM profile had no capture section at all, so no userspace tool could
   select the microphone.
2. `TX SMIC MUX0` was set to `ADC1`, which is not a valid enum value on this
   SoC; the correct one is `SWR_MIC0`.
3. `ADC1_MIXER Switch` was never enabled, so the DAPM chain broke at `ADC1`.
4. The unused decimators (`ADC2`, `ADC3`, `ADC2_MIXER`,
   `TX_AIF1_CAP Mixer DEC1`) were left enabled and added audible hiss to the
   ADC1 recording (L RMS 5168.4 -> 122.6).
5. The capture mixer also opened the right channel, which the codec never
   produces (`1,1` -> `1,0`).

Separately, the silent `EIO` that made this look unfixable came from PipeWire
refusing to release the PCM — `pkill` is not enough, `systemctl --user stop` is.

The working settings live in the `Mic` and `HeadsetMic` sections of
`tapas-HiFi.conf`. After the UCM profile is applied, the card state must be
identical to `/root/tapas-alsa-working.state`; this check is how the hiss was
found.

Capture is **stereo**. The two internal microphones fill the two channels
independently (left = handset, right = top). The headset boom microphone is a
single source, so it feeds both decimators from its one SoundWire slot and the
recording carries it on both channels instead of only the left one.

`qcom,tx-port-mapping` was changed to `<1 2 3 4>` in the Tapas DTS. That is a
real fix and should be kept: with `<1 1 2 3>` both ADCs were mapped onto master
port 1 and enabling ADC2 corrupted ADC1's stream (~5100 rms of hiss). With the
new mapping ADC1 stays clean (60.7 rms) next to ADC2.

**Still open:** the third microphone input (AMIC4 / ADC3) has never been tried.

---

## 2. Proximity sensor (tmd2755)

The sensor **is visible and produces data** through the Snapdragon Sensor Core,
but it never reports `NEAR`.

The earlier "No proximity sensor" failure was a systemd boot race and is fixed.
The remaining problem is different: the value the DSP produces never gets close
to the configured threshold.

- Measured raw `distance`: **12–15** with nothing in front, **15–17** with an
  object present — only ~3 counts of modulation.
- Registry thresholds are stock: `near_threshold 95.0`, `far_threshold 50.0`,
  `crosstalk 10.0`, `offset 0.0`.
- The value moves in the right direction, so polarity is not the issue.
- The ALS on the same chip works fine (0 lux covered, 143.8 lux in daylight),
  so I2C, the power rails and the DSP path are all healthy.
- Registry and `sensors/config` are byte-identical to Android, and Android
  reports `NEAR` with the same hardware.

**Next step:** change `proxconfig` `c[1]` from 2816 to 1408 and reboot, to learn
whether the DSP honours that group at all. The DSP reads the registry only at
ADSP boot, so a normal reboot is required; `remoteproc` stop/start is forbidden.

---

## 3. Camera

Three of the four cameras **work**: rear main (S5KJN1), front (S5K3L6) and
ultra wide (OV08D10) all stream raw Bayer frames. The macro module (GC02M1)
probes and even reports itself as streaming, but no frame ever arrives.

- CAMSS has a `CAMSS_6225` profile. The TFE really is `vfe_ops_340`, but the
  CSIPHY is the SM8250 v1.2.1 core (`lane_regs_sm8250`, not the QCM2290 table),
  and the camera AXI clock needs its own rate table.
- The blocker turned out to be the PLL, not the ISP: GPLL10 was described as a
  DEFAULT_EVO PLL copied from SM6115, while SM6225 uses Lucid and also needs the
  FSM legacy mode bit cleared out of the configure path. Until both were fixed
  the TFE clock source never locked and streaming failed with `-EBUSY`/`-110`.
- CPAS turned out not to be needed for a sensor RDI capture.
- The front camera needed a new driver (`s5k3l6`, ported from an unmerged RFC
  series); the OV08D10 driver is upstream. The macro has no driver that works.
- Also working: the VAF actuator (Giantec GT9764 over `dw9719`), the rear main
  EEPROM, the flash LED (Kinetic KTD2691), mounting rotation for the three
  working modules, and libcamera tuning generated from the vendor chromatix
  blobs.
- There is still no ISP/3A, so colour comes from libcamera's software ISP, and
  autofocus is reachable from the kernel but not from libcamera 0.7.2.

**Next step:** the macro sensor, then line-based RDI programming so a GPU can
import the buffers without a copy, then a real autofocus algorithm.

---

## 4. Video decode

Hardware decoding works through `iris` (`/dev/video12` decoder,
`/dev/video13` encoder), with H.264, HEVC and VP9 all verified: a 60-frame
640x480 stream decodes to 60 correct frames through GStreamer's `v4l2*dec`
elements.

Getting there took more than a driver swap:

- The vendor `venus.mbn` speaks HFI Gen2, which the `venus` driver never
  supported, so the node was handed to `iris` instead. `venus` skips its
  QCM2290 compatible when `iris` is built.
- `iris` had no AR50 LITE (the video core in this SoC) platform support; the
  upstream AR50LT/Agatti series was applied, plus twelve fixes from the
  Motorola fogona port.
- The video carveout had to move to the vendor's layout, including a 7 MiB
  `pil_video_mem`.
- `gcc_vcodec0_gdsc` needed `HW_CTRL_TRIGGER`, otherwise `iris` fails core init
  with `-EOPNOTSUPP`.
- AR50 LITE firmware has no UBWC interface and answers the first UBWC property
  with a fatal system error, so those properties are suppressed for it.

---

## 5. Voice call

Parked. The UCM `Voice Call` verb exists and is written correctly, the modem
registers and the call is tracked by ModemManager (with the pre-alerting state
patch applied), and the DSP accepts the voice graph's open payload, the VCPM
parameters and the sink format — but it rejects `GRAPH_PREPARE` on the graph,
so no audio flows.

Everything needed to resume is archived in `sources/tapas-voice-poc/`: the two
reverted kernel commits as patches, the graph blob builder and its input
tooling, the generated blobs, the UCM files, the watcher script and a README
recording what was measured. See `issues/voice-call.md` for the detail.

---

## Notes

- Only what was actually measured is claimed as verified. The microphones
  work; the proximity sensor was measured but is unresolved; three cameras
  stream raw frames and produce debayered images, the fourth does not; hardware
  decode was exercised end to end; call audio does not work.
- The device is reachable as `ssh tapas`; the build and packaging VM as
  `ssh debian`.
