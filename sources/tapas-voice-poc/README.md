# Voice call on tapas — parked work (status 2026-11-15)

Everything needed to pick this up again, and why it stopped where it did.

The kernel side lives in two commits that were reverted from `sm6225` so the
branch stays clean; `patches/` holds them as they were, ready for
`git am`. Nothing here is installed on the device any more.

## What works

* The DSP accepts the *open* of stock's voice RX and TX graphs, and the run
  that follows a clean boot gets as far as `GRAPH_PREPARE`.
* VCPM is configured and accepted (`rc = 0` for all four):
  `vsid = 0x11c05000` (param `0x080011bc`), tx channel map (`0x08001310`),
  calibration keys (`0x0800116b`), and the MFC output format (48 kHz,
  16-bit, 2 ch, FL|FR) for `0x41dd` / `0x465b`.
* The CODEC DMA sink inside the voice graph takes its media format
  (`0x43b3`, params `0x08001017` / `0x08001018` / `0x08001063` / `0x8001176`),
  yet `GRAPH_START` still answers with a bare DSP failure.
* The earpiece path itself is good: with the Voice Call profile active, plain
  music played into `hw:0,0` comes out of the receiver.

## Where it stops

`GRAPH_PREPARE` (RX) returns `DSP returned error[1001001] 2` → `-22`.
Opcode map in `audioreach.c`: `1001000` open, `1001001` prepare,
`1001002` start, `1001003` stop, `1001004` close, `1001006` set_cfg.

The current hypothesis, and the reason fogona does it differently: the stock
device sub-graph `0xb000002a` inside the voice graph carries its own CODEC DMA
sink, and that sink belongs to the playback graph ALSA already owns. Fogona
drops `0xb000002a` entirely and remaps the chain onto its own topology
(`RX_MAP`, `RX_BRIDGE`), so the voice graph never reaches for a backend that
another graph owns. That remap needs a multi-input SAL and a splitter in the
tapas `.m4`; both were written and then removed with the rest of this work —
see `kernel/wip-notes.md` for what they looked like.

## Measured facts worth keeping

* **A failed `start` leaves the DSP sticky.** After any failure, the same boot
  rejects the next `open` with `-22` even for a blob that opened fine before.
  Every meaningful test needs a reboot (~2 min).
* **No ALSA PCM may be open when the voice graph is opened.** With
  `aplay -D hw:0,0 /dev/zero &` running, `GRAPH_OPEN` fails with
  `error[1001000] 1`; with every PCM closed the same blob opens. This is the
  opposite of fogona's note ("the backend has to be running before the voice
  RX graph opens"), and it is why the watcher starts the graphs before
  opening its own PCMs.
* **APM does not validate cross-graph edges.** Pointing `0x41dc:1` at a
  non-existent instance `0x6fff:3` still reports success, so a green `start`
  says nothing about whether the bridge was actually made.
* Sub-graph lists for PREPARE/START/STOP must match the open payload exactly,
  including stock's device sub-graph when it is present.
* DIAG/PCM logging is not available on this port: no `/dev/diag`, no
  `qcom-diag` or `diag-router` package in Debian, no diag service on QRTR, and
  mainline has no `CONFIG_DIAG_CHAR`.
* Auto-answer/modem plumbing was fine throughout: `mmcli` reported
  `registered / lte / attached`, and ModemManager with the `PRE_ALERTING`
  patch (see `plans/02-voice-call.md` §2.9) tracked the call as `active`.

## Contents

    patches/    the two reverted kernel commits (export hooks, PoC module),
                and userspace/ with the ModemManager, libqmi and
                msm-firmware-loader patches that get an incoming IMS call
                reported and its MCFG served
    kernel/     q6apm-voice-poc.c as committed, plus wip-notes.md
    tools/      tapas-voice-graphs.py (blob generator) and helpers,
                fogona-voice-graphs.py for reference, acdbdump.c + log_stub.c
    blobs/      generated graph payloads: vg-stock (4 sub-graphs,
                self-contained), vg-3sg (stock device sub-graph removed),
                vg-sal / vg-rxcal / vg-fe / vg-bogus (bridge experiments)
    device/     tapas-VoiceCall.conf, tapas.conf in both states, and
                tapas-voice-call-watch with its unit
    tests/      the shell scripts used to drive the tests on the device

## To resume

1. `git am patches/*.patch` on `sm6225` (they apply on top of `1f40020cd15c`).
2. The userspace side is independent of the audio work and can go in first:
   `patches/userspace/libqmi` and `.../modemmanager` make an incoming VoLTE
   call visible as ringing-in at all, and `.../msm-firmware-loader` exposes
   the fsg partition so `tqftpserv` can serve the MCFG to the modem.
3. Rebuild the topology with the SAL and splitter, regenerate the blobs with
   `tools/tapas-voice-graphs.py` (RX without `0xb000002a`, bridge
   `(0x41dc, 1, <sal>, 3)`), and see whether `GRAPH_START` finally passes.
4. If it does, check that the DSP receives anything at all before chasing the
   earpiece again; without DIAG the only signal is whether the receiver makes
   sound during a call.