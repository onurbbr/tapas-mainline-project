# Forensic device trees

Decompiled device trees taken from the vendor images of this device
(`images/` on the build machine, not tracked). They are the reference used
throughout `docs/`: whenever a board detail was unclear — a GPIO, a rail, a
lane — the answer came from here.

Regenerate with `mkforensics.py` in this directory; nothing here is edited by
hand.

| File | Source | Lines | Contents |
|---|---|---|---|
| `merged-fdt.dts` | `images/fdt` | 16 098 | The merged device tree the bootloader hands to Android: base SoC plus every overlay applied |
| `tapas-overlay.dts` | `images/dtbo.img`, entry 45 | 3 533 | Only the Tapas board overlay (`board-id 20022,0`, `msm-id 0x206`) |
| `base-soc.dts` | `images/vendor_boot.img` | 13 851 | The bare Khaje/SM6225 SoC tree (`msm-id 0x24a`), no board data |

Notes on the extraction:

- `dtbo.img` has a big-endian header (magic `0xd7b7ab1e`) with 49 entries.
  Entry 45 is the one whose model string is
  `Qualcomm Technologies, Inc. KHAJE IDP nopmi tapas`.
- `vendor_boot.img` is header version 4. The embedded DTB sits at offset
  15 024 128, is 1 305 239 bytes long and is loaded at `0x1f00000`. The
  header is not laid out the way the field order suggests — it starts with
  the magic, then the version, and the command line and name are fixed-size
  arrays — which is why the offsets in the script look odd.
- The camera nodes live in the overlay, not in the base tree: the base tree
  has a stub `bolero-codec` and no sensors.

Related, and also not in this repository: the vendor kernel and device tree
sources under `/home/onur/Projects/Linux/sources/xiaomi/`
(`android_kernel_xiaomi_sm6225-devicetrees`, `camera-kernel`,
`vendor_qcom_opensource_camera-kernel`, `vendor_qcom_opensource_audio-kernel`,
`kernel_devicetree`).
