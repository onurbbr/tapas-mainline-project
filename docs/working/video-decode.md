# Tapas — video decode

**Status: working.** H.264, HEVC and VP9 decode end to end in hardware.

| | |
|---|---|
| Driver | `iris` (`CONFIG_VIDEO_QCOM_IRIS`) |
| Nodes | `/dev/video12` decoder, `/dev/video13` encoder |
| Core | AR50 LITE |
| Firmware | vendor `venus.mbn`, 1 852 708 bytes, `video-firmware.2.6` |
| Firmware path | `/lib/firmware/qcom/venus-6.0/venus.mbn` |

## Why not `venus`

The vendor image speaks **HFI generation 2**. `venus` only implements
generation 1, so it loads the image, sends generation-1 packets, receives a
fatal error and times out. `iris` supports both generations and picks one by
inspecting the image, so this device has to go through `iris`.

Both drivers match the same compatible string, so only one may bind. When
`CONFIG_VIDEO_QCOM_IRIS` is enabled, `venus` does not register the
`qcom,qcm2290-venus` compatible at all, and the device tree's
`"qcom,sm6225-venus", "qcom,qcm2290-venus"` falls through to `iris`.

```
&venus {
	status = "okay";
	firmware-name = "qcom/venus-6.0/venus.mbn";
};
```

The `firmware-name` override is required: without it `iris` looks for the
generation-2 image under a different name, gives up and falls back to the
generation-1 descriptor while still loading this very firmware.

## Measured result

```
v4l2-ctl -d /dev/video12 --list-formats     -> NV12, Q08C, P010, Q10C
v4l2-ctl -d /dev/video12 --list-formats-out -> H264, HEVC, VP90
```

Decoding 60 frames of each codec with GStreamer:

| codec | pipeline | result |
|---|---|---|
| H.264 | `h264parse ! v4l2h264dec` | 60/60 frames, 27 648 000 B |
| HEVC | `h265parse ! v4l2h265dec` | 60/60 frames, 27 648 000 B |
| VP9 | `ivfparse ! v4l2vp9dec` | 60/60 frames, 27 648 000 B |

The output was checked rather than just counted: luma spans 6–244 (full
range), chroma sits at 127–128 (neutral), and consecutive frames differ, so
the buffers carry a moving picture and not silence.

`v4l2-ctl --stream-from/--stream-count` produces zero bytes on this driver,
which is why the tests use GStreamer.

## Three fixes it needed

1. **Memory carveout.** `pil_video_mem` is 7 MiB at `0x55b17000`, matching the
   vendor layout. The generic layout used 5 MiB at `0x51400000`, which is too
   small for this firmware and cannot grow in place.

2. **`gcc_vcodec0_gdsc` needs `HW_CTRL_TRIGGER`.** Without the flag
   `gdsc_init()` installs no `set_hwmode_dev` callback,
   `dev_pm_genpd_set_hwmode()` returns `-EOPNOTSUPP` and core init fails with
   `-95`. `gcc-sm6115` already carries the flag on the same `0x58098`
   register.

3. **AR50 LITE has no UBWC configuration interface.** Its firmware answers the
   first UBWC property with `HFI_SYS_ERROR_FATAL`, and because the error
   handler recovers by deinit followed by init, the core never comes up and
   the driver spins — on this SoC roughly every 130 ms. The platform data now
   carries `no_ubwc_props` and `SYS_INIT` is sent without them.

Three more, from the developer of a sibling device, were needed before the
first frame: an IRQ teardown deadlock on the core-init error path, a
rejected `HFI_CMD_RESUME` that carried a payload, and buffer accounting
around stop and source change. All twelve fixes are in the 7.4 tree.

## Known gaps

- Content protection is not described for this SoC yet; the sibling platform
  uses a different layout (`cp_size 0x70800000`).
- The encoder node exists but was not exercised.
