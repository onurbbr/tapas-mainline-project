#!/usr/bin/env python3
"""Rebuild the three forensic DTS files from the vendor images.

Everything is derived from the images in ~/Projects/Debian/development/images,
so the output can be regenerated at any time; nothing here is hand edited.
"""
import os
import struct
import subprocess
import sys

IMG = os.path.expanduser("~/Projects/Debian/development/images")
OUT = os.path.expanduser("~/Projects/Debian/development/sources/forensics")

DTBO_MAGIC = 0xD7B7AB1E
# The Tapas overlay is the entry whose board-id is 20022 and whose msm-id
# starts with 0x206; see the walk below rather than a fixed index.
TAPAS_BOARD_ID = (0x20022, 0)
TAPAS_MSM_ID = 0x206


def dtc(dtb, dst, label):
    subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dst, dtb],
                   check=False)
    print("%-14s %6d lines" % (label, sum(1 for _ in open(dst))))


def make_merged():
    dtc(os.path.join(IMG, "fdt"), os.path.join(OUT, "merged-fdt.dts"),
        "merged-fdt")


def make_overlay():
    data = open(os.path.join(IMG, "dtbo.img"), "rb").read()
    magic, total, hdr_size, entry_size, num, entry_off, page, version = \
        struct.unpack_from(">8I", data, 0)
    if magic != DTBO_MAGIC:
        sys.exit("dtbo.img: bad magic %#x" % magic)

    found = None
    for i in range(num):
        off = entry_off + i * entry_size
        size, offset, dtb_id, rev, _ = struct.unpack_from(">5I", data, off)
        blob = data[offset:offset + size]
        # Cheap textual probe first: only the Tapas overlay names the device.
        if b"tapas" not in blob:
            continue
        path = "/tmp/dtbo-%d.dtb" % i
        open(path, "wb").write(blob)
        dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", path],
                             capture_output=True, text=True)
        if "nopmi tapas" in dts.stdout or "tapas" in dts.stdout:
            found = (i, path)
            break

    if not found:
        sys.exit("dtbo.img: no entry mentions tapas")
    idx, path = found
    print("dtbo entry     %d (id %d)" % (idx, dtb_id))
    dtc(path, os.path.join(OUT, "tapas-overlay.dts"), "tapas-overlay")


def make_base_soc():
    data = open(os.path.join(IMG, "vendor_boot.img"), "rb").read()
    # struct vendor_boot_img_hdr_v4: header_version comes first, and the
    # command line and the name are fixed-size arrays, so the offsets are
    # not the ones a naive reading of the field order suggests.
    header_version, page_size = struct.unpack_from("<I", data, 8)[0], \
        struct.unpack_from("<I", data, 12)[0]
    ramdisk_size = struct.unpack_from("<I", data, 24)[0]
    header_size, dtb_size = struct.unpack_from("<2I", data, 2096)
    dtb_addr = struct.unpack_from("<Q", data, 2104)[0]
    if header_version < 3:
        sys.exit("vendor_boot.img: header v%d has no dtb" % header_version)
    if not dtb_size:
        sys.exit("vendor_boot.img: no embedded dtb")

    off = ((header_size + page_size - 1) // page_size) * page_size
    off += ((ramdisk_size + page_size - 1) // page_size) * page_size
    if off + dtb_size > len(data):
        sys.exit("vendor_boot.img: dtb runs past the end of the file")

    path = "/tmp/vendor-boot.dtb"
    open(path, "wb").write(data[off:off + dtb_size])
    print("vendor dtb     v%d header %d offset %d size %d addr %#x"
          % (header_version, header_size, off, dtb_size, dtb_addr))
    dtc(path, os.path.join(OUT, "base-soc.dts"), "base-soc")


os.makedirs(OUT, exist_ok=True)
make_merged()
make_overlay()
make_base_soc()
