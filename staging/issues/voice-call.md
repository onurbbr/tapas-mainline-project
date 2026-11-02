# Voice call audio

Status: **open, blocked on a missing kernel/userspace graph builder**

Media playback and capture work. Call audio does not, and this document
records why, what was ruled out, and which routes remain.

## 1. What "call audio" requires on this SoC

The modem does not hand call audio to the application processor as PCM. The
DSP owns the voice path: it runs the vocoder, the echo canceller and the
noise suppressor, and it is the only thing that can mix a call into the
codec. Linux therefore has to ask the DSP to start a voice graph and then
make the codec listen to it.

Two stacks exist for that conversation:

- **Legacy APR / q6voice.** Services `q6mvm`, `q6cvs`, `q6cvp` on the
  `apr_audio_svc` GLINK channel, with a `VoiceMMode1` hostless front end.
  This is what Fairphone 5 and the sc7280 trees use.
- **AudioReach / VCPM.** The `VCPM` module inside an AudioReach voice
  subgraph, driven over the same GPR protocol that q6apm already speaks.

The two are mutually exclusive in the device tree, because one needs the
`apr` node and the other the `gpr` node under the same remoteproc.

## 2. Legacy APR is not available on this firmware

Checked on the device, not assumed:

- `/sys/bus/rpmsg/devices/` under `a400000.remoteproc` lists only
  `adsp_apps`, `fastrpcglink-apps-dsp`, `glink_ssr`, `IPCRTR`,
  `LOOPBACK_CTL_LPASS` and `rpmsg_ctrl`. There is no `apr_audio_svc`
  channel. GLINK channels come from SMEM at firmware build time; they
  cannot be created later.
- Concatenating `adsp.b00..b32` (16,737,727 bytes) and scanning the strings:
  `apr_audio_svc` → 0 hits, `MVM` → 0, `CVP` → 0. The 75 hits for `CVS`
  are all `DCVS` (dynamic clock and voltage scaling) and unrelated.

So `q6mvm`/`q6cvs`/`q6cvp` and the `VoiceMMode1` DAI cannot bind here even
if the drivers were ported. The sc7280 recipe does not transfer.

## 3. VCPM is present and is the intended path

The same firmware dump is full of VCPM: `vcpm_utilities.c`,
`vcpm_utility_update_vsid`, `vcpm_utility_update_vcpm_properties`,
`vcpm_utility_are_stream_sgraphs_in_start_state`,
`apm_proxy_vcpm_utils.c` with `identified Voice Proxy for SG[..]`, and the
`VCPM_PARAM_ID_*` and `VCPM_CAL_KEY_ID_*` parameter names. So the DSP side
is complete and modern.

Mainline already knows the identifiers but implements nothing:

- `sound/soc/qcom/qdsp6/audioreach.h`: `VCPM_MODULE_INSTANCE_ID 0x4`,
  `APM_SUB_GRAPH_SID_AUDIO_VOICE_CALL 0x3`
- `include/dt-bindings/soc/qcom,gpr.h`: `GPR_VCPM_MODULE_IID 4`

Neither constant is referenced anywhere. `audioreach-topology` has
`APM_SUB_GRAPH_SID_VOICE_CALL` defined as `0x3`, but no voice subgraph
template and no VCPM module macro, and the shipped `.m4` for this device
contains no voice graph at all.

## 4. Who drives VCPM on Android

Not the kernel. All 237 modules in `vendor_dlkm.img` and `vendor.img` were
scanned: zero hits for `vcpm`, `vsid`, `voicemmode` or `voice_call`. The
only audio modules are transports (`audio_pkt_dlkm`, `audio_prm_dlkm`,
`gpr_dlkm`, `swr_dlkm`, the macro and codec modules).

The client is in userspace:

| library | hits |
|---|---|
| `libar-pal.so` | 20 (`SessionAlsaVoice::populate_vsid_payload`, `populateVSIDLoopbackPayload`, `payloadSetVSID`) |
| `libar-acdb.so` | 36 (`GetVcpmSubgraphCalTable`, `GetVcpmMasterKeyTable`, `BuildVcpmBlob`) |

`audioreach-pal` is BSD-3-Clause and public. `SessionAlsaVoice.cpp` (2206
lines) shows there is no private protocol: it sends ordinary AudioReach
module parameters with `module_instance_id = VCPM_MODULE_INSTANCE_ID` and
`param_id = VCPM_PARAM_ID_TX_DEV_PP_CHANNEL_INFO`, carrying the `vsid`, then
starts the graph with `PAL_PLUGIN_CONFIG_START`. q6apm can already emit
`APM_CMD_SET_CFG` and `APM_CMD_GRAPH_OPEN`, so the kernel side is not the
missing piece.

## 5. Where the graph description actually lives

This is the part that decides feasibility, so it was checked directly.

**Android ships no topology file at all.** Searching `vendor.img` and
`vendor_dlkm.img` for `*tplg*`, `*.gbt`, `*audioreach*` and any audio `.bin`
returns nothing but the mixer paths XML. There is no APM subgraph container
on the Android side.

**`IDP_acdb_cal.acdb` is the graph and calibration database.** Its chunk
stream is fully enumerable:

```
HEAD GKVT GKVL CSLU CAKT CDLU CDDE CDDO
SCLU SCDE SCDO MTKT MTLU MTDE MTDO TMLU TMDE
PPTC SGIT POOL MODM BTUP VCCD VCMK VCKT VCLU VCDE MTKL GPRO HASI
```

Decoded structure:

- `SCLU` — 628 entries of 16 bytes, keyed by ACDB subgraph ID:
  **268 distinct subgraph containers** (`0xb0000001` … `0xb000014d`).
- `MTKT` — 270 entries of 12 bytes `(subgraph, master key, offset)`:
  201 distinct subgraphs, 32 master keys spanning `0xc0000004` …
  `0xc0001013`.
- `VCDD`, `VCMK`, `VCKT`, `VCLU`, `VCDE` — the VCPM set:
  **67,900 bytes of VCPM subgraph calibration data**, 468 bytes of VCPM
  master keys, 124 bytes of VCPM calibration key table, plus its lookup
  and data chunks.

The chunk names line up one to one with the `libar-acdb.so` symbols
(`GetVcpmSubgraphCalTable`, `GetVcpmMasterKeyTable`,
`GetVcpmCalibrationKeyIDTable`, `GetVcpmSubgraphChunkData`,
`BuildVcpmBlob`). So ACDB does hold the voice-call calibration, and the DSP
will apply it once a voice graph runs.

What ACDB does **not** yield is the module chain. The `Graph Key Vector`
table only maps graph keys to subgraph IDs; which modules sit inside each
subgraph, in what order, with which port IDs, comes from the design
workspace. `IDP_workspaceFileXml.qwsp` (715,584 bytes) is that workspace
and it is **encrypted** — high-entropy bytes, no gzip/zip/xz/bzip2/XML
signature anywhere. It is not readable without the vendor tooling.

## 6. Consequence

The blocker is not the DSP, not the codec, not UCM, and not a missing
parameter. It is that:

1. mainline q6apm builds graphs from a topology container, while
2. the only place this device's voice graph is described is an encrypted
   vendor workspace, and
3. the component that turns ACDB plus that workspace into an
   `APM_CMD_GRAPH_OPEN` module list is userspace AGM/PAL, which has no
   mainline equivalent.

Legacy APR would have avoided all of that, but the firmware does not expose
it.

## 7. Remaining routes

Ordered by cost, cheapest first.

**a. Recover the subgraph layout from a running Android session.** Boot
Android with a call active and capture the GPR traffic to the ADSP, then
replay the same `APM_CMD_GRAPH_OPEN` module list from Linux. This needs
glink tracing on the Android side and is the only route that produces the
exact vendor module chain. Substantial effort, no guessing.

**b. Try a minimal hand-built voice subgraph.** The `.m4` language can
express scenario ID `0x3`, and a voice graph plausibly needs only the
VCPM module plus a codec DMA sink and source. This is guesswork against a
closed firmware contract; a wrong graph risks upsetting the audio PD, and
we have already seen how fragile that is. Only worth attempting with a
way to recover quickly.

**c. Do not implement call audio.** Media is fully working. Calls would
have to stay on Android or on another device.

There is no path where the existing kernel and UCM work is reused
unchanged: whichever route is taken, a voice graph has to be opened by
something that does not exist in mainline today.

## 8. What is in place for when this is picked up

- The HiFi verb keeps the receiver path alive (`RDAC3_MUX = RX3`,
  `RX_EAR Mode Switch`) even though the Earpiece device is no longer offered
  to media, so the voice verb reuses it.
- A `Voice Call` verb now exists (`tapas-VoiceCall.conf`, registered in
  `tapas.conf`). It exposes a **single** playback endpoint, `Call`, plus the
  `Mic` capture endpoint. Speaker and headset are UCM *modifiers* on that one
  endpoint, so a desktop never lists "Earpiece playback" and "Speaker
  playback" as separate outputs while a call is running:

  ```
  set _enadev Call        # start the call endpoint (earpiece by default)
  set _enamod Speaker     # earpiece -> loudspeaker
  set _dismod Speaker     # back to the earpiece
  set _enamod Headphones  # earpiece -> wired headset
  set _dismod Headphones  # back to the earpiece
  set _disdev Call        # end the call endpoint
  ```

  Verified by reading the mixer state back after each step: the earpiece
  route (`Receiver Switch`, `EAR_RDAC Switch`) and the speaker route
  (`Speaker Switch`, `AUX_RDAC Switch`) are mutually exclusive, and the
  headset modifier clears both before powering the HPH path.
- Call playback uses **MultiMedia2** (`RX_CODEC_DMA_RX_0`), which nothing
  else opens, so a call and a media stream can coexist. Media keeps
  MultiMedia1.
- The ACDB files are already shipped through hexagonrpcd, so the DSP can
  read the VCPM calibration without any packaging change.

## 9. ACP exposes the voice verb as a card profile

`spa.alsa` turns every UCM verb into a card profile, so `Voice Call` shows
up next to `HiFi (...)` in the desktop's card configuration. That cannot be
suppressed from UCM. It is kept harmless by priority: HiFi profiles weigh
8200-8300, the voice profile 4200, so profile selection picks HiFi unless
someone asks for the voice verb explicitly.

Selecting it by hand does what it says: the sink becomes "Call audio",
`MultiMedia2` is routed and the earpiece is powered. WirePlumber then stores
that choice in `~/.local/state/wireplumber/default-profile` and re-applies
it on every boot, which looks like "media suddenly plays from the earpiece".
Deleting that file (or the matching `[default-profile]` line) returns the
card to HiFi.

`spa.alsa` also prints `Can't match media roles for modifier Speaker` and
`... for modifier Headphones` at startup. ACP only binds a modifier to a
media role it knows, and there is no role for "call on the loudspeaker", so
the modifiers are only reachable through `alsaucm`. A daemon that owns the
call state would issue those commands itself; nothing in the desktop stack
does it today.

## 10. Not verified

No call has been placed with any of the above. All statements about the
firmware are from string scans, device sysfs listings and file format
parsing. The UCM verb was exercised with `alsaucm` and `wpctl set-profile`
and the resulting mixer state was read back, but no call has produced audio
on this port.
