# Topology changes for the voice-call remap (removed, described here)

These were made in `/home/onur/Projects/Linux/audioreach/audioreach-topology`
and reverted with `git checkout` when the work was parked. The built
`Xiaomi-Redmi-Note-12-4G-tplg.bin` in the firmware package is back to the
plain media layout (LOG → MFC → CODEC_DMA), so the voice graphs currently have
no SAL of their own to bridge into.

Why it was needed: fogona's working voice call does not reuse stock's device
sub-graph. It drops `0xb000002a` and lands the voice chain on its own
multi-input SAL inside the playback device sub-graph. That needs a SAL and a
splitter in our `.m4` too.

## New files

`audioreach/module_sal.m4` — `AR_MODULE_SAL(index, sgidx, container-idx, iid,
maxip, maxop, src-port, dst-in-port, dst-iid)`, `MODULE_ID_SAL 0x07001010`
(stock's `0x40e1` is the same module id). Multi-input, so the voice chain and
the media stream can both feed it.

`audioreach/module_splitter.m4` — `AR_MODULE_SPLITTER(index, sgidx,
container-idx, iid, maxip, maxop, src-port, dst-in-port, dst-iid)`,
`MODULE_ID_SPLITTER 0x07001011`, widget type `buffer`. Its extra outputs are
what feed the echo reference (`0x4448` input 4) from the playback side.

`audioreach/audioreach.m4` gained both `MODULE_ID_SPLITTER` and
`MODULE_ID_SAL` next to `MODULE_ID_VOL_CTRL`.

## Playback device sub-graph

`audioreach/subgraph-device-codec-dma-playback.m4` became:

    LOG 0x6070 → SAL 0x6074 → MFC 0x6071 → SPLITTER 0x6073 → CODEC_DMA_RX_0 0x6072

with IIDs `MOD_IID_START + 0..4` (LOG, MFC, CDC, SPLIT, SAL). `AR_MODULE_LOG`'s
destination iid moves to `SAL_MODULE_IID`; the SAL feeds the MFC; the MFC feeds
the splitter; the splitter feeds the sink. `DEVICE_PLAYBACK_ROUTE` line order
follows: logger → sal → mfc → splitter → codec_dma_rx → playback.

Blob side after that: `RX_SGS` without `0xb000002a`,
`RX_MAP = {0x43b3: 0x6072}`, `RX_BRIDGE = [(0x41dc, 1, 0x6074, 3)]`,
`TX_BRIDGE = [(0x6090, 1, 0x4448, 2), (0x6073, 3, 0x4448, 4)]`.

## Building

    cd /home/onur/Projects/Linux/audioreach/audioreach-topology/build
    nix-shell -p cmake m4 alsa-utils --run "cmake .. && make topology_Xiaomi-Redmi-Note-12-4G"

Trap: if the CMake cache came from another directory, `rm -rf build` first, and
if `.conf`/`.bin` do not refresh, `rm -f build/qcom/sm6225/*`. Three warnings
about `undefined sink widget/stream` for `RX_CODEC_DMA_RX_0 Playback`,
`VA_CODEC_DMA_TX_0 Capture` and `TX_CODEC_DMA_TX_3 Capture` are expected.

This layout was built and installed and did **not** solve the failure on its
own: with the voice graph rebridged onto the new SAL, `GRAPH_OPEN` was fine but
`GRAPH_START` still answered `error[1001002] 1`.
