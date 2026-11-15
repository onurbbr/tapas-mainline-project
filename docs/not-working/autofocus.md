# Tapas — autofocus

**Status: not working in userspace.** The kernel side is complete and was
measured; nothing above it drives the lens.

| | |
|---|---|
| Actuator | Giantec GT9764 voice coil |
| I2C | CCI0, 7-bit `0x0c` |
| Driver | `dw9719` in DW9800K mode, `compatible = "giantec,gt9764", "dongwoon,dw9800k"` |
| Supply | `cam_vaf_2p8`, a `regulator-fixed` on TLMM 101 at 2.8 V |
| Control | `V4L2_CID_FOCUS_ABSOLUTE`, 0–1023 |

## The kernel side works

- `focus_absolute` moves the lens: writing 64/255/256/512/1023 puts
  0x0040/0x00ff/0x0100/0x0200/0x03ff into the DAC.
- Sharpness changes with position on a real frame (centre gradient metric
  11.31 at one end, 6.37 at the other).
- The lens is parked at DAC 367 after probe, the value the vendor module
  declares as its initial code, so a session that never touches focus still
  produces a usable picture.

Two vendor details had to be reproduced: the actuator needs `0x02 = 0x02`,
`0x06 = 0x40` and `0x07 = 0x67` at power-up, and the position is a single
16-bit write to `0x03`. `dw9768` clears `0x02` and puts the part to sleep, so
`dw9719` is the correct driver even though the part is in the dw9768 family.

## Why userspace cannot focus

Four layers were checked, and three of them have no autofocus at all:

1. **Kernel** — present and working, see above.
2. **libcamera 0.7.2** — the software ISP has no AF algorithm, so
   `cam -c 1 --list-controls` offers only `Saturation`, `Contrast` and
   `Gamma`. No `AfMode`, `AfTrigger`, `AfState` or `LensPosition`. Loading an
   `Af` tuning section makes the IPA fail to initialise.
3. **GStreamer** — `libgstlibcamera.so` has the enum symbols but the element
   exposes no AF property.
4. **PipeWire / portal** — `libspa-libcamera.so` has no AF or focus mapping,
   and the camera portal forwards no controls. GNOME Snapshot contains no AF
   code either.

So there is no path from any installed application to the V4L2 control.

## What it would take

An autofocus implementation in the libcamera software IPA, plus the plumbing
to expose it through libcamera's camera controls. Continuously running AF also
needs a sharpness or contrast metric over the RAW frames, which the software
ISP already computes for its own statistics.

Until then the lens stays at its parked position and can be moved by hand with
`v4l2-ctl` for testing.
