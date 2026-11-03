# Tapas — project status

Xiaomi Redmi Note 12 4G (tapas / SM6225) mainline port.

- Kernel branch: `sm6225`, based on `c03c1a14507d` (Linux v7.3), 48 commits
- Running kernel on device: `7.3.0-sm6225-upstream+`
- Distribution: Debian, booting from SD card (Android on the other boot slot)

Per-topic details, measurements and dead ends live in `issues/`.

---

## Open topics

| # | Topic | Status | Blocker | Size | File |
|---|-------|--------|---------|------|------|
| 1 | Microphone (capture) | **WORKING** — handset and headset microphone, both PCM channels | Third microphone (ADC3) untested | Small | `issues/microphone.md` |
| 2 | Proximity sensor | **PARTIAL** — visible, never changes state | Raw `distance` reported by the DSP is in the 12–17 range; thresholds are 95/50 | Medium, uncertain | `issues/proximity.md` |
| 3 | Camera | **OPEN** — none of it works | No SM6225 support in mainline CAMSS, no CPAS model | Large | `issues/camera.md` |
| 4 | Voice call | **OPEN** — UCM verb ready, no call audio | Firmware exposes only AudioReach VCPM, no legacy APR; mainline has no VCPM graph builder. The `Voice Call` verb (single `Call` endpoint plus speaker/headset modifiers) is written and its routing verified, but the DSP voice graph cannot be opened yet | Large | `issues/voice-call.md` |

None of these are regressions. They were either deliberately out of scope for the
initial port or have no mainline counterpart yet.

---

## 1. Microphone

Both microphones **work**: the handset microphone (AMIC1) and the boom
microphone of a wired headset (AMIC2). The UCM profile switches between them on
the `Mic Jack` control, the same way `Headphones` takes over from `Speaker`.

Handset path:

```
AMIC1 -> ADC1 -> ADC1_OUTPUT --SoundWire--> TX SWR_INPUT0
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC0)
      -> TX_AIF1_CAP Mixer DEC0 -> TX_CODEC_DMA_TX_3
      -> MultiMedia4 Mixer -> hw:0,3
```

Headset path:

```
AMIC2 -> ADC2 MUX (INP2) -> ADC2 -> ADC2_OUTPUT --SoundWire--> TX SWR_INPUT4
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC4)
      -> TX DEC1 MUX (SWR_MIC) -> TX SMIC MUX1 (SWR_MIC4)
      -> TX_AIF1_CAP Mixer DEC0 + DEC1 -> TX_CODEC_DMA_TX_3
      -> MultiMedia4 Mixer -> hw:0,3
```

The boom microphone is a single ADC, so both decimators are fed from the same
SoundWire slot and the stereo PCM carries the microphone on both channels
(correlation 0.9986). The slot number is
`SWR_MICn = (master_port - 1) * 4 + (channel - 1)`; ADC2 is on master port 2
channel 1, which is `SWR_MIC4`. Earlier attempts used `SWR_MIC1`, where nothing
is transmitted, which is why ADC2 looked dead for several sessions while the
vendor stack (which configures channel 2 and therefore reads `SWR_MIC5`)
worked.

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

Capture is **stereo**. The handset microphone duplicates DEC0 into DEC1 so the
right channel carries the same signal, and the headset microphone feeds both
decimators from its single SoundWire slot for the same reason. A mono sensor on
a stereo PCM should not lose the right channel.

`qcom,tx-port-mapping` was changed to `<1 2 3 4>` in the Tapas DTS. That is a
real fix and should be kept: with `<1 1 2 3>` both ADCs were mapped onto master
port 1 and enabling ADC2 corrupted ADC1's stream (~5100 rms of hiss). With the
new mapping ADC1 stays clean (60.7 rms) next to ADC2.

**Still open:** the third microphone (AMIC4 / ADC3) has never been tried.

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

No stage of it works. The hardware map and the vendor software stack are
understood, but mainline has no counterpart.

- Four cameras, all on CCI: rear main (S5KJN1), front (S5K3L6 / OV13B10),
  rear ultra (OV08D10), rear macro (GC02M1 / OV2680 / HI259) — the fitted part
  varies by production batch.
- `drivers/media/platform/qcom/camss/camss.c` has **no SM6225 support at all**;
  the vendor stack is built around `qcom,cam-cpas` + TFE0-2 + OPE, and mainline
  CAMSS does not model CPAS.
- The `camss@5c11000` node in our `sm6225.dtsi` is `status = "disabled"`, has no
  port endpoints, and nothing binds `"qcom,sm6225-camss"` — dead description.
- `cci@5c1b000` does bind through the `"qcom,msm8996-cci"` fallback, so CCI I2C
  is usable.
- Sensor drivers: `s5kjn1`, `ov08d10`, `ov13b10` and `ov2680` exist in mainline;
  `s5k3l6`, `gc02m1` and `hi259` do not.
- The `wl2866d` camera PMIC driver was ported (commit 44) but has no consumers
  yet, so its rails are marked `always-on`.

**Next step:** add an SM6225 resource table to CAMSS. The 7.2 attempt is kept as
a reference but was speculative and should not be carried over blindly.

---

## Notes

- Only what was actually measured is claimed as verified. The microphone was
  measured and works; the proximity sensor was measured but is unresolved; the
  camera was never exercised at all.
- The device is reachable as `ssh tapas`; the build and packaging VM as
  `ssh debian`.
