# Tapas — microphone / audio capture

**Status:** WORKING (single microphone, mono) · multiple microphones open
**Last updated:** 2026-11-01 · kernel `7.3.0-sm6225-upstream+`, branch `sm6225`
**Related commits:** 27 (island CODEC DMA), 29 (soundwire resume), 30 (wcd937x
earpiece), 31 (VA macro 2.1), 32 (AW87XXX), 33 (Tapas sound card)

---

## 1. Summary

The handset microphone (AMIC1) **works**. A 4 s capture on `hw:0,3` gives
768 044 bytes, `frames 192000 ch 2 rate 48000`, left channel
`max 19128 min -21698`, `nonzero 191988` — real audio, not silence. Also
verified through PipeWire with the UCM profile (`pw-record`, stereo 48 kHz).
Clean reference capture: L RMS **122.6**, peak **+3401 / −4314**.

The working settings are written into `SectionDevice."Mic"` in `tapas-HiFi.conf`.
Once applied, the card state must be identical to
`/root/tapas-alsa-working.state`; if it is not, the UCM profile has a missing or
extra cset (this is how the hiss problem was found).

Capture is currently **stereo with both channels carrying the handset mic**,
i.e. the right channel duplicates the left. This is a deliberate temporary
workaround: the real second microphone (AMIC2/ADC2) is wired and its codec path
powers up, but it delivers no SoundWire audio on this board. See section 5.

`qcom,tx-port-mapping` in the Tapas DTS is now `<1 2 3 4>` (was `<1 1 2 3>`);
that change stopped ADC2 from corrupting ADC1. It is a real fix and should be
kept regardless of how the ADC2 question is resolved.

---

## 2. Working path

```
AMIC1 -> ADC1 -> ADC1_OUTPUT --SoundWire--> TX SWR_INPUT0
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC0)
      -> TX_AIF1_CAP Mixer DEC0 -> TX_AIF1 CAP
      -> TX_CODEC_DMA_TX_3 -> MultiMedia4 Mixer -> hw:0,3
```

Control numids and values:

| numid | control | value |
|---|---|---|
| 19 | `ADC1 Switch` | 1 |
| 102 | `ADC1_MIXER Switch` | 1 |
| 10 | `ADC1 Volume` | 12 |
| 189 | `TX DEC0 MUX` | `SWR_MIC` |
| 197 | `TX SMIC MUX0` | `SWR_MIC0` |
| 157 | `TX_AIF1_CAP Mixer DEC0` | 1 |
| 153 | `MultiMedia4 Mixer TX_CODEC_DMA_TX_3` | 1,0 (left only) |
| 151 | `MultiMedia3 Mixer TX_CODEC_DMA_TX_3` | 0,0 |
| 20 | `ADC2 Switch` | 0 |
| 21 | `ADC3 Switch` | 0 |
| 103 | `ADC2_MIXER Switch` | 0 |
| 158 | `TX_AIF1_CAP Mixer DEC1` | 0 |

The UCM profile uses `CapturePCM "hw:${CardId},3"` (MultiMedia4).

Capture requires two channels but the codec path is mono (AMIC1 -> ADC1), so
only the left channel is mixed in (`1,0`). The right channel stays silent.

**The unused decimators (ADC2, ADC3, DEC1) are explicitly muted.** When they are
left enabled their inputs add audible hiss to the ADC1 recording even though
nothing is routed through them — measured: L RMS 122.6 (clean) vs 5168.4 (with
ADC2/ADC3/DEC1 enabled).

---

## 3. Real bugs found

1. **The UCM profile had no capture section at all.** No userspace tool could
   select the microphone. `SectionDevice."Mic"` was added.
2. **`TX SMIC MUX0` was set to `ADC1`, an enum value that does not exist on this
   SoC.** SM6225 uses `smic_mux_text_v9_2[]` (`lpass-tx-macro.c:1837-1840`) with
   the item list `ZERO, SWR_MIC0..SWR_MIC11`; the valid value is **`SWR_MIC0`**.
   The old `ADC0..ADC3` names apply to `LPASS_VER_9_0_0` and older.
3. **`ADC1_MIXER Switch` (numid 102) was never enabled.** The wcd937x DAPM chain
   is `ADC1_OUTPUT <- ADC1_MIXER <- ADC1 REQ <- ADC1 <- AMIC1`; with the mixer
   kcontrol closed the chain broke at `ADC1: Off in 1 out 0`, the TX macro never
   got its clock, and the capture PCM returned a silent `EIO`.
4. **Capture FE/BE pairing.** The topology wires both `MultiMedia3` and
   `MultiMedia4` front ends to `TX_CODEC_DMA_TX_3`, but on this board only the
   **MultiMedia4 <-> TX_CODEC_DMA_TX_3** pair produces data.
5. **The unused decimators stayed enabled.** `ADC2 Switch`, `ADC3 Switch`,
   `ADC2_MIXER Switch` and `TX_AIF1_CAP Mixer DEC1` persist once enabled (vendor
   UCM profiles leave them on too). Even with no microphone attached to them
   they add hiss to the ADC1 recording: L RMS 5168.4 -> **122.6**. The UCM
   profile now explicitly mutes all four in `EnableSequence`.
6. **The right channel was opened for nothing.** With `MultiMedia4 Mixer` at
   `1,1` the right channel, which the codec never produces, was mixed into the
   PCM as well. Changed to `1,0`.

---

## 4. Dead ends (recorded so they are not repeated)

- **`pkill pipewire` is not enough.** It usually releases the PCM but sometimes
  leaves it held, and `arecord` then returns a silent `EIO`. The correct way:
  ```
  export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
  systemctl --user stop pipewire.socket pipewire-pulse.socket wireplumber.service pipewire.service
  ```
  This was the actual source of a long-standing "EIO" illusion — there was
  nothing wrong in the device tree.
- **`swr0 clocks = <&txmacro>` -> `<&vamacro>`** was tried: the TX slave went
  from `Alert` to `Attached` (a real, permanent improvement) but capture still
  failed. It is currently **reverted** to `<&txmacro>`; no DTS change is in place.
- **Aligning the port arrays with `kodiak.dtsi`** was tried, had no effect, and
  was reverted.
- **Adding `<&wcd9370 1>, <&swr0 0>` to the `va-dai-link` codec list** locked up
  the kernel (`va_macro_tx_mixer_put` -> `snd_soc_dpcm_runtime_update` deadlock,
  `controls_rwsem` held forever). Reverted — **must not be repeated.**
- **`qcom,tx-port-mapping = <1 1 2 3>` -> `<2 2 3 4>`** was tried, following
  Android's `ADC1 ChMap = SWRM_TX2_CH1`. It produced **no sound at all** on this
  board, not even mono. Reverted to `<1 1 2 3>`.

---

## 5. Second microphone (AMIC2 / ADC2): workaround in place

### 5.1 What was tried and measured (2026-11-01)

The path is described in the device tree:

```
AMIC2 -> ADC2 MUX (INP2) -> ADC2 -> ADC2_OUTPUT -> TX SWR_INPUT1
      -> TX SMIC MUX1 (SWR_MIC1) -> TX DEC1 MUX (SWR_MIC)
      -> TX_AIF1_CAP Mixer DEC1 -> TX_AIF1 CAP
```

`qcom,tx-port-mapping` was changed from `<1 1 2 3>` (both ADCs on master port 1)
to **`<1 2 3 4>`** (each ADC on its own master port) in
`arch/arm64/boot/dts/qcom/sm6225-xiaomi-tapas.dts`. This fixed the cross-talk:

| configuration | left (ADC1) | right (ADC2) |
|---|---|---|
| `<1 1 2 3>`, ADC1 only | 60-66 rms | 0.0 |
| `<1 1 2 3>`, ADC1 + ADC2 | ~5100 rms (hiss) | 0.0 |
| `<1 2 3 4>`, ADC1 and ADC2 | **60.7 rms (clean)** | 249 rms, one burst then all zero |

So with the new mapping ADC2 no longer corrupts ADC1. But ADC2 itself still
produces **no audio**: after a single start-up transient (0.2-0.45 s, peak
~3500) the right channel is exactly 0 for the rest of the capture.
`ADC2 MUX = INP3` instead of `INP2` makes it dead silent, so `INP2` is the
correct input.

### 5.2 Everything upstream of the slave port is confirmed good

DAPM during a capture with ADC2 enabled shows the whole chain powered:

```
ADC2: On in 1 out 1        ADC2_MIXER: On in 1 out 1
ADC2 MUX: On in 1 out 1    (INP2 -> AMIC2)
ADC2_OUTPUT: On in 1 out 1 (to TX SWR_INPUT1 and VA SWR_MIC4)
AMIC2: On in 1 out 1       MIC BIAS2: On in 0 out 0
```

SoundWire is symmetric on both sides:

- Slave DP1 `0x120 CHANNELEN = 1`, DP2 `0x220 CHANNELEN = 1`
  (bank1 `0x132`/`0x232` = 3, `0x134`/`0x234` = 1 and 2).
- Master DP1 `0x1124 = 0x1000103` (en_chan = 0x01),
  DP2 `0x1224 = 0x1000203` (en_chan = 0x02).

So both ports are enabled, the master enables the right channel, and the codec
analog block is powered - yet the samples are zero.

Feeding `TX SMIC MUX1` from a DMIC (`TX DEC1 MUX = MSM_DMIC`, `TX DMIC MUX1` =
DMIC0..DMIC3) produced **byte-identical** right-channel data for all four DMIC
inputs (348.5 rms, same peak, same nonzero count), i.e. that transient is not
audio at all but a fixed start-up artifact of DEC1.

### 5.3 The DEC1 -> AIF1 -> DMA half of the chain is proven

Pointing the second decimator at ADC1 instead of ADC2:

```
TX DEC1 MUX = SWR_MIC, TX SMIC MUX1 = SWR_MIC0, TX_AIF1_CAP Mixer DEC1 = 1
MultiMedia4 Mixer TX_CODEC_DMA_TX_3 = 1,1
```

gives a right channel that is a **copy of the left** (correlation 0.9855,
L rms 62.8 / R rms 64.1). So everything from the TX macro's second decimator
onwards works; only the ADC2 -> SoundWire source is dead.

### 5.4 Decision: stereo workaround, documented as temporary

Both decimators are now fed from `SWR_MIC0` (ADC1). The capture device stays
stereo (the topology only allows two channels) and both channels carry the same
signal instead of a silent right channel.

This is a **workaround, not the final design**. The UCM file says so explicitly
in the `Mic` section header. Replace `TX SMIC MUX1` with `SWR_MIC1` and restore
`ADC2`/`ADC2_MIXER` once the reason ADC2 produces no SoundWire data is found.

Suspects still open:

- the codec's second ADC/data port needs something mainline does not program
  (vendor DT carries `qcom,tx_swr_ch_map` with per-channel `0x493e00` fields and
  a vendor-only `ADC1 ChMap` control that mainline does not have);
- `qcom,micbias2-microvolt = <2800000>` here vs `2700000` in the vendor overlay
  (all three micbias rails are 2.7 V downstream) - untested, would need a reboot;
- the top microphone may physically be a DMIC rather than AMIC2; the vendor DT
  does define `cdc-dmic01-gpios`/`cdc-dmic23-gpios`, but DMIC0..3 all produced
  the same fixed transient, which points away from a DMIC source as well.

---

## 6. Reference files

Obsolete profiles and ALSA dumps are not kept in this repository; previous
versions of `tapas-HiFi.conf` are recoverable from the git history.

- `/root/tapas-HiFi.conf.bak-stereo` (on the device) - the mono UCM profile that
  preceded the stereo workaround.
- `/root/tapas-alsa-working.state` (on the device) - the `alsactl store -f` dump
  of the working control set, used as the reference described below.

The active file is
`debian:~/Projects/Debian/development/staging/device/usr/share/alsa/ucm2/Qualcomm/sm6225/tapas/tapas-HiFi.conf`.
`staging/device` mirrors the installed layout exactly and `build-debs.sh` packs
it with `cp -a`, so the path in the tree is the path in the package.

The `.state` file is used as a reference: after the UCM profile is applied,
`alsactl store -f /tmp/now.state && diff /root/tapas-alsa-working.state
/tmp/now.state` must be **empty**. If it is not, the profile has a missing or
extra cset — this is exactly how the hiss problem was found.

---

## 7. Harmless warnings

```
wcd937x_codec: supply vdd-mic-bias not found, using dummy regulator
wcd937x_codec: missing qcom,mbhc-buttons-vthreshold-microvolt entry
va_macro a730000.codec: qcom,dmic-sample-rate dt entry missing
qcom-soundwire a740000.soundwire: din-ports (3) mismatch with controller (4)
qcom-soundwire a610000.soundwire: dout-ports (5) mismatch with controller (6)
```

The `din-ports`/`dout-ports` warnings are harmless: `qcom_swrm_read_prop()`
(`drivers/soundwire/qcom.c:1439-1464`) reads the value reported by the hardware,
then overrides it with the device tree value and only logs the difference. The
vendor tree uses 3 DIN ports as well.

The `vdd-mic-bias` supply is absent from the vendor DT too
(`qcom,cdc-static-supplies = "cdc-vdd-rxtx", "cdc-vddpx"`), so it is not a
regression.

---

## 8. Next steps

1. Find out why ADC2 produces no SoundWire data even though the slave port, the
   master port and the whole codec DAPM chain are enabled (see 5.4 for the
   suspects). Remove the stereo workaround once solved.
2. The DSD/third microphone (AMIC4 -> ADC3 -> `TX SWR_INPUT2`) has never been
   tried.
3. Speaker protection / ACDB calibration is a separate topic.
