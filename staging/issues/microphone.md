# Tapas — microphone / audio capture

**Status:** WORKING (handset, top and headset microphone)
**Last updated:** 2026-11-03 · kernel `7.3.0-sm6225-upstream+`, branch `sm6225`
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

## 5. Second microphone (AMIC2 / ADC2) and the headset boom microphone

Status: **WORKING**. For several sessions ADC2 looked dead; the ADC was fine,
the SoundWire slot was wrong.

### 5.1 Root cause: the slot number

```
SWR_MICn = (master_port - 1) * 4 + (channel - 1)
```

ADC2 is on SoundWire master port 2 (`qcom,tx-port-mapping = <1 2 3 4>`) and its
slave port mask is `BIT(0)`, so the master drives channel 1 and the TX macro
input is **`SWR_MIC4`**, sourced from `TX SWR_INPUT4`. Earlier attempts selected
`SWR_MIC1` (master port 1, channel 2): nothing is transmitted there, so the
stream started but every sample was zero. The vendor stack names the same wire
`ADC2 ChMap = SWRM_TX2_CH2` / `SWR_MIC5` because it configures channel 2; the
mainline driver derives the channel from the slave port mask, so it lands on
channel 1 and `SWR_MIC4`.

The device tree now carries `"TX SWR_INPUT4", "ADC2_OUTPUT"` (commit
`3702cc433a15`).

### 5.2 Verified on hardware

| configuration | result |
|---|---|
| ADC2, DEC0, `TX SMIC MUX0 = SWR_MIC4` | rms 382, max 2744, nonzero 235387/240000 - real audio |
| ADC2, DEC0, `TX SMIC MUX0 = SWR_MIC5` | EIO, 44 bytes |
| ADC1 (SWR_MIC0) and ADC2 (SWR_MIC4) together | two independent signals, correlation 0.183 |
| Android reference, same headset | `TX SMIC MUX0 = SWR_MIC5`, `ADC2 MUX = INP2`, boom mic audible |

`ADC2 MUX` must be `INP2`; `INP3` is not connected to the boom microphone.

### 5.3 The capture is stereo, the microphone is mono

The boom microphone is a single ADC, so it only fills one SoundWire slot. With
one decimator enabled the recording was audible on the left channel only, while
music playback was fine on both sides.

Fix: feed **both** decimators from the same slot.

```
TX DEC0 MUX = SWR_MIC    TX SMIC MUX0 = SWR_MIC4
TX DEC1 MUX = SWR_MIC    TX SMIC MUX1 = SWR_MIC4
TX_AIF1_CAP Mixer DEC0 = 1, DEC1 = 1
```

Measured after the change:

| path | left | right | correlation |
|---|---|---|---|
| raw `arecord -D hw:0,3` | rms 277.4 | rms 284.9 | 0.9652 |
| `pw-record` through the UCM headset source | rms 166.7 | rms 167.0 | 0.9986 |

Both channels carry the same microphone, which is what a mono headset mic on a
stereo PCM should look like. This is the same trick that was used earlier to
duplicate DEC0 into DEC1, except that the source is now the real ADC2 data
instead of a copy of ADC1.

### 5.4 What the UCM does now

`tapas-HiFi.conf` has four devices: `Speaker`, `Headphones`, `Mic` (AMIC1 and
AMIC3) and `HeadsetMic` (AMIC2, `JackControl "Mic Jack"`, `JackHWMute "Mic"`).
Plugging a wired headset switches the source to the boom microphone
automatically and hides the internal microphones, the same way `Headphones`
hides `Speaker`. Verified on the phone: with a headset plugged in both internal
microphones go silent and the boom microphone takes over; unplugging it brings
them back.

Details worth keeping:

* `ADC3 Switch` is never touched. ADC2 and ADC3 share the second slave port and
  its channel mask, so clearing the ADC3 switch also closes the ADC2 data path.
* Neither capture device has a `CaptureSwitch` and neither has a
  `DisableSequence`. ACP probes a UCM profile by opening the PCM and treats the
  capture switch as a mute control; anything that tears the route down makes the
  profile unsupported, the card falls back to the `off` profile and WirePlumber
  creates a dummy output.
* `ADC2 MUX` decides which of the two ADC2 inputs is used: `INP3` for the top
  microphone (internal capture) and `INP2` for the headset boom microphone.
  They are never enabled at the same time.

### 5.5 Still open

* The headset boom microphone is duplicated across both channels because it is a
  single-channel source on a stereo PCM. That is correct for a mono boom mic; a
  stereo headset microphone would need a real second ADC.
* The headset microphone was only checked with the gaming headset (TRRS with a
  boom mic). Nothing else was tested.
* The third internal microphone input (AMIC4 / ADC3) has never been tried.

### 5.6 Top microphone (AMIC3 / ADC2 on INP3)

The phone has a second internal microphone at the top edge. Like the headset
boom microphone it is wired to **ADC2**; only the analog input differs:

| microphone | ADC | `ADC2 MUX` | TX macro slot |
|---|---|---|---|
| headset boom | ADC2 | `INP2` | `SWR_MIC4` |
| top (internal) | ADC2 | `INP3` | `SWR_MIC4` |

Confirmed against Android with a stereo ("interview") recording. Snapshotted the
vendor mixer state before and during the recording; only these changed:

| control | before | during |
|---|---|---|
| `ADC2 MUX` | INP2 | **INP3** |
| `ADC1_MIXER Switch` | Off | **On** |
| `ADC2_MIXER Switch` | Off | **On** |
| `TX DEC0 MUX` | MSM_DMIC | **SWR_MIC** |
| `TX DEC1 MUX` | MSM_DMIC | **SWR_MIC** |
| `TX SMIC MUX0` | ZERO | **SWR_MIC9** |
| `TX SMIC MUX1` | ZERO | **SWR_MIC4** |
| `ADC1 ChMap` | ZERO | SWRM_TX2_CH1 |
| `TX_AIF1_CAP Mixer DEC0` / `DEC1` | Off / Off | **On / On** |
| codec `0x300e` / `0x300f` / `0x3010` | 2c / 0c / 2c | **ac / 8c / ac** |
| codec `0x3022` / `0x3025` (MICB1 / MICB3) | 22 / 22 | **62 / 62** |

So the vendor HAL runs **both** ADCs at once, one per decimator: ADC1 (handset)
and ADC2 (top). After the recording the state returns to the idle values, so
nothing is left half-configured.

### 5.7 Both internal microphones run together

That is the behaviour the UCM profile now implements. With no cable plugged in,
`SectionDevice."Mic"` enables both ADCs, one per decimator, so the stereo
capture carries the handset microphone on the left channel and the top
microphone on the right one:

```
AMIC1 -> ADC1 -> ADC1_OUTPUT --SoundWire--> TX SWR_INPUT0
      -> TX DEC0 MUX (SWR_MIC) -> TX SMIC MUX0 (SWR_MIC0)
      -> TX_AIF1_CAP Mixer DEC0 -> hw:0,3 left

AMIC3 -> ADC2 MUX (INP3) -> ADC2 -> ADC2_OUTPUT --SoundWire--> TX SWR_INPUT4
      -> TX DEC1 MUX (SWR_MIC) -> TX SMIC MUX1 (SWR_MIC4)
      -> TX_AIF1_CAP Mixer DEC1 -> hw:0,3 right
```

Plugging a headset with a microphone switches to `HeadsetMic`, which turns
`ADC1` off, moves `ADC2 MUX` to `INP2` and feeds both decimators from that one
source, so the two internal microphones stop contributing.

Measurements (no cable plugged in):

| test | left (ADC1) | right (ADC2, INP3) | correlation |
|---|---|---|---|
| idle room noise, `arecord -D hw:0,3` | rms 73.7 | rms 58.5 | 0.167 |
| tapping the **top edge** microphone | rms 48.8 | **rms 11285.1** | -0.018 |
| `pw-record` through the UCM source | rms 65.1 | rms 30.5 | 0.176 |

The second row is the proof: tapping the top microphone lifts the right channel
by a factor of ~190 while the left channel stays at room-noise level, and the
two channels are uncorrelated. Before that test the same setup had already been
checked with `TX SMIC MUX0 = SWR_MIC4`, where nothing is transmitted, and the
right channel was exactly zero - so an empty channel had looked like "INP3 is
dead" rather than "the slot is wrong".

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

1. The third microphone (AMIC4 -> ADC3 -> `TX SWR_INPUT5` / `SWR_MIC8`) has
   never been tried; the device tree route is in place but no UCM device uses
   it.
2. Speaker protection / ACDB calibration is a separate topic.
3. Voice call audio is blocked on the DSP side, see `issues/voice-call.md`.
