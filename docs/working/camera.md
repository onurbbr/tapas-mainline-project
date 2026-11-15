# Tapas — camera

**Status:** PARTIAL · rear main, front and ultra wide capture RAW frames ·
macro sensor and the ISP stage still open
**Last updated:** 2026-11-10 · kernel `7.3.0-sm6225-upstream+`, branch `sm6225`
**Related commits** (branch `sm6225`, 104 commits in total): `9814a087230b`
FSM legacy mode in the Trion configure path · `764d4cdf7844` GPLL10/GPLL11 as
Lucid PLLs · `d066ce363a18` CAMSS SM6225 support · `c2ef6f64c443` rear main
camera wiring · `41d720cee42c`+`478e5c4f4c83` S5K3L6 binding and driver ·
`c0619a7c3fac`+`dbfd5fec0cc4` front camera · `a27881d40978` front facing ·
`5d95520d1810` ultra wide · `73bf5c2798bd` S5KJN1 virtual channel and crop ·
`e2f1525e7b51` GT9764 · `529cfda5a524` KTD2691 · `2e3bb88853a3` EEPROM, focus
and flash · `62be2bfb720a` rear rotation · `d81b1c7cc4b8`+`cd989c720f3d`
wl2866d · `b15ad95c5241` dma-buf heap

---

## 1. Summary

The rear main camera works: `/dev/video0` streams a 8160x6144 RAW10 frame.

The frame is raw Bayer with no ISP stage behind it, so it is dark green
noise to look at until it is debayered and white balanced by userspace. The
sensor's own exposure and gain defaults are what you get.

What was needed:

1. **CAMSS:** a SM6225 profile in the driver. The blocks are the QCM2290
   ones, but the CSIPHY is the v1.2.1 revision, whose lane register layout
   differs from the QCM2290 table, and the camera AXI clock needs its own
   rate table.
2. **Clocks:** GPLL10 and GPLL11 were described as DEFAULT_EVO PLLs, copied
   from SM6115. SM6225 uses Lucid, and the Trion configure path also has to
   drop the PLL out of firmware (FSM legacy) mode. Without both, the TFE
   clock source never locked and every streaming attempt failed before a
   single byte was written.
3. **Device tree:** the PHY rails had to move from the SoC dtsi to the
   board, and the sensor and CSIPHY0 endpoints had to be connected.

Where the four modules stand:

| Module | Role | State |
|---|---|---|
| S5KJN1 | rear main | **works** — RAW10, binned 4080x3072 (30 fps) and full 8160x6144 (10 fps) |
| S5K3L6 | front | **works** — RAW8 2104x1560, driver written for this port |
| OV08D10 | ultra wide | **works** — RAW10 3264x2448, upstream driver |
| GC02M1 | macro | **does not work** — probes and reports streaming, no frame ever arrives; parked |

Also in place: the VAF actuator (Giantec GT9764), the rear main EEPROM
(24C256 class), the flash LED (Kinetic KTD2691), mounting rotation for the
three working modules, and libcamera tuning generated from the vendor
chromatix blobs.

Still open: the macro sensor, the ISP/3A stage, autofocus in userspace,
line-based RDI programming, and the calibration data the vendor keeps in the
EEPROMs.

---

## 2. Hardware map

Extracted from the vendor overlay (`dtbo.img` entry45, board-id `20022,0`,
msm-id `0x206`).

| Role | DT node | CCI master | CSIPHY | MCLK | Reset GPIO | Extra |
|---|---|---|---|---|---|---|
| Rear main (wide) | `cam-sensor0` | 0 | 0 | MCLK0 | TLMM 18 | EEPROM0, VAF actuator, flash0 |
| Front | `cam-sensor1` | 1 | 2 | MCLK1 | TLMM 24 | EEPROM2 |
| Rear ultra | `cam-sensor2` | 1 | 1 | MCLK2 | TLMM 19 | EEPROM1, CSI mux sel TLMM 100, flash |
| Rear macro | `cam-sensor3` | 0 | 1 | MCLK3 | TLMM 68 | EEPROM3, custom GPIO1 TLMM 99 |

Additional components:

- **EEPROMs:** four (`qcom,eeprom`), each with its own MCLK/reset;
  `cam_clk-supply = <&gcc_camss_top_gdsc>`.
- **VAF (autofocus) actuator:** `qcom,actuator0`, CCI master 0,
  `cam_vaf-supply = <&cam_vaf_2p8>` — a 2.8 V `regulator-fixed` controlled from
  TLMM 101.
- **Flash:** three `camera-flash@0/1/2` nodes (`qcom,camera-flash`),
  `flash-type = 1` (LED).
- **Camera PMIC:** `wl2866d@28` (`ovti,wl2866d-i2c` / `willsemi,wl2866d`),
  enable on TLMM 26, `id_reg 0x03` / `id_val 0x64`. Four rails: DVDD1, DVDD2,
  AVDD1, AVDD2.
- **Pinctrl:** `cam_sensor_mclk0..3_active/suspend` (TLMM 20/21/27/28, function
  `cam_mclk`), the reset states, `cam_sensor_rear0_vaf` (101) and
  `cam_sensor_csi_mux_sel` (100). Note: `cam_sensor_csi_mux_oe` has
  `pins = [00]` in the vendor dump — empty/dummy, no real pin.

### Sensors actually fitted

Tapas was built with **nine different module variants** (batch dependent):

```
m7_sunny_s5kjn1_wide_i      m7_ofilm_s5kjn1_wide_ii
m7_aac_ov08d10_ultra_i      m7_ofilm_ov08d10_ultra_ii
m7_aac_s5k3l6_front_i       m7_qtech_ov13b10_front_ii
m7_ofilm_gc02m1_macro_i     m7_sunny_ov2680_macro_ii
m7_truly_hi259_macro_iii
```

The module names in that list do not match what this unit reports. The
vendor camera stack prints a line per module while it probes, and the chip
IDs it reads only agree with the rear main sensor:

```
Probe success,slot:0,slave_addr:0x20,sensor_id:0x38     s5kjn1   rear main
Probe success,slot:1,slave_addr:0x20,sensor_id:0x30c6   s5k3l6   front
Probe success,slot:2,slave_addr:0x6c,sensor_id:0x5647   ov08a10  rear ultra
Probe success,slot:3,slave_addr:0x6e,sensor_id:0x2e0    gc02m1   rear macro
```

So this unit has **S5KJN1 + S5K3L6 + OV08A10 + GC02M1**, not the
`ov13b10`/`ov08d10`/`ov2680` combination the package names suggest. The
address is the 8-bit one, so the 7-bit address is half of it.

### Measured on this unit

Addresses, buses and power sequencing were read back from the vendor stack
while each camera was opened from the factory test application.

| slot | role | part | 7-bit addr | CCI | MCLK | reset |
|---|---|---|---|---|---|---|
| 0 | rear main | s5kjn1 | 0x10 | 0 | gpio20 | gpio18 |
| 1 | front | s5k3l6 | 0x10 | 1 | gpio21 | gpio24 |
| 2 | rear ultra | ov08a10 | 0x36 | 1 | gpio27 | gpio19 |
| 3 | rear macro | gc02m1 | 0x37 | 0 | gpio28 | gpio68 |

WL2866D rail usage, as logged by the vendor stack:

| module | rail | voltage |
|---|---|---|
| rear main | DVDD2 | 1050 mV |
| rear main | AVDD2 | 2800 mV |
| front | DVDD1 | 1200 mV |
| front | AVDD1 | 2800 mV |
| rear ultra | AVDD1 | 2800 mV |
| rear macro | AVDD1 | 2800 mV |

The rear main sensor is the only module that uses DVDD2 and AVDD2. Every
other module runs from AVDD1, which is why that rail is always on.

Two extra resource lines belong to modules without a mainline driver: the
rear ultra sits behind a CSI lane mux on gpio100, and the macro module has
a VIO enable on gpio99.

### What was tried and did not work

The two auxiliary sensors that mainline does have a driver for were
described and powered, and neither of them probes:

* `ov08d10` at 0x36 on CCI 1 does not acknowledge at all, with either reset
  polarity and on either CCI bus.
* `ov2680` at 0x37 on CCI 0 acknowledges on the bus but reads 0x0000 from
  its chip ID register instead of 0x2680.

Both failures are explained by the part identification above: the fitted
parts are an ov08a10 and a gc02m1, and neither has a mainline driver.

### Mainline sensor driver status

| Sensor | Mainline driver | File |
|---|---|---|
| S5KJN1 (wide) | **PRESENT** | `drivers/media/i2c/s5kjn1.c` |
| OV08D10 (ultra) | **PRESENT** | `drivers/media/i2c/ov08d10.c` |
| OV13B10 (front) | **PRESENT** | `drivers/media/i2c/ov13b10.c` |
| OV2680 (macro) | **PRESENT** | `drivers/media/i2c/ov2680.c` |
| S5K3L6 (front) | **MISSING** | — |
| GC02M1 (macro) | **MISSING** | — |
| HI259 (macro) | **MISSING** | — |

> Important correction: the initial port claimed "`s5kjn1` is Spes-specific and
> was excluded". In reality `s5kjn1.c` **is already in mainline 7.3**; the only
> difference in 7.2 was a few `dev_info("s5kjn1: streaming write ret=%d")` debug
> lines. Nothing was lost on the sensor driver side.

---

## 3. Vendor software stack

From the vendor DT (`sources/forensics/tapas-overlay.dts`) and the
`/vendor`, `/vendor_dlkm`
images:

```
qcom,cam-cpas@5c11000         compatible "qcom,cam-cpas", arch-compat "cpas_top"
  ├── qcom,csiphy0/1/2        "qcom,csiphy-v1.2.1"
  ├── qcom,cci0/1             "qcom,cci-v1.2"
  ├── csid0/1/2
  ├── tfe0/1/2
  ├── ope0
  ├── cdm
  └── tpg
qcom,cam_smmu                 msm_cam_smmu_{tfe,ope,cpas_cdm,secure}
qcom,cam-req-mgr
qcom,cam-res-mgr
```

Modules:
- `/vendor_dlkm/lib/modules/camera.ko` — the actual camera driver
- `/vendor_dlkm/lib/modules/leds-qti-flash.ko` — flash LED
- `/vendor/lib64/camera/com.qti.sensor.*` — CAMX userspace sensor modules
- `/vendor/etc/camera/` — golden calibration files (s5kjn1 sunny/ofilm, LDC
  packdata, morpho XML)

The critical point: the vendor stack is centred on **CPAS** (`cam-cpas`). CPAS
is the layer that manages the camera NOC/data path and feeds the TFE/OPE blocks.
**Mainline CAMSS has no such concept.**

---

## 4. State on the mainline side

### SM6225 is a CAMSS profile now

Commit 53 adds `CAMSS_6225` to `camss.c` with its own `csiphy_res_6225`,
`csid_res_6225`, `vfe_res_6225` and `icc_res_6225` tables, and registers
`qcom,sm6225-camss`.

It is close to the QCM2290 profile — same `csid_ops_340`, `vfe_ops_340` and
`csiphy_ops_3ph_1_0` — but three things differ and each of them broke the
pipeline when it was wrong:

1. **CSIPHY lane table.** The downstream node is `qcom,csiphy-v1.2.1`, which
   is the SM8250 core, and the register stride is 0x2000. Programming the
   QCM2290 table leaves the PHY deaf: no interrupt, no byte in the RDI
   buffer, no error. `lane_regs_sm8250` is the right table.
2. **Camera AXI clock.** `gcc_camss_axi_clk_src` sits at its 19.2 MHz reset
   rate unless a rate is listed for the `axi` clock. At 50 MP RAW10 that
   overflows the CSID RDI FIFO, so `vfe_res_6225` lists 19.2/150/240/300 MHz
   for it and the driver scales it with the pixel clock.
3. **PLL.** See below.

### The PLL was the real blocker

`gcc-sm6225.c` described GPLL10 and GPLL11 as DEFAULT_EVO PLLs, with the
SM6115 configurations. Both frequencies (1152 MHz and 600 MHz) are inside the
declared VCO range, so nothing complained at boot. But the TFE takes its pixel
clock from GPLL10 through an RCG that divides it by 7.5, and that RCG never saw
a running parent:

```
gcc_camss_tfe_0_clk_src: rcg didn't update its configuration.
WARNING: drivers/clk/qcom/clk-rcg2.c:136 at update_config
qcom-camss 5c11000.camss: clock enable failed: -16
```

Switching both PLLs to Lucid changed the failure rather than fixing it:

```
wait_for_pll.constprop.0+0xcc
clk_trion_pll_enable+0xb0
alpha_pll_lucid_prepare+0x8c
qcom-camss 5c11000.camss: clock enable failed: -110
```

The Lucid configure path never set `PLL_FSM_LEGACY_MODE`, so the firmware state
machine stayed in charge of the loop filter and the PLL never locked on the
programmed dividers. Commits 51 and 52 set the bit in
`clk_trion_pll_configure()` when a PLL asks for it, and describe GPLL10/GPLL11
as Lucid with `SUPPORTS_FSM_LEGACY_MODE`.

After that the RCG locks at 153.6 MHz and the pipeline starts.

### The `camss` node works

`arch/arm64/boot/dts/qcom/sm6225.dtsi` already described the whole block:
regions for the top, the three CSIDs, the three CSIPHYs and the three TFEs,
20 GCC clocks, the interrupts, the three interconnect paths, four SMMU
streams, the MX/CX/TOP power domains and the OPP table. All of it was usable
and none of it had to change, apart from moving the two CSIPHY rails out.

Those rails were hardcoded to PM6125 L4 and L18 in the SoC dtsi, which is only
true for boards that use that PMIC. They are board specific, so they moved to
`sm6225-xiaomi-tapas.dts`.

Commit 54 sets `status = "okay"`, adds the supplies and connects the sensor
endpoint to the CSIPHY0 endpoint. Only the PHY side needs describing: the
driver links every CSIPHY to every CSID and every CSID line to every TFE line
by itself.

### Resulting pipeline

```
s5kjn1 0-0010                /dev/v4l-subdev18   SGRBG10_1X10/8160x6144
  -> msm_csiphy0             /dev/v4l-subdev0
  -> msm_csid0               /dev/v4l-subdev3
  -> msm_vfe0_rdi0           /dev/v4l-subdev6
  -> msm_vfe0_video0         /dev/video0
```

Measured on the unit:

```
CSIPHY 3PH HW Version = 0x40010000
VFE:0 HW Version = 1.2.0
CSID:0 HW Version = 1.0.3
VFE0: Started client 7 width 8160 height 6144 stride 10200
v4l2-ctl ... --stream-count=1   -> 62668800 bytes
```

62668800 is exactly 8160 * 6144 * 10 / 8, one RAW10 frame. Histogram: mean
36.8, 99.9 % non-zero, two dominant byte values. Rendered as 8-bit greyscale
the frame shows the ceiling of the room.

### CCI works

```dts
cci: cci@5c1b000 {
	compatible = "qcom,sm6225-cci", "qcom,msm8996-cci";
	...
};
```

The `"qcom,msm8996-cci"` fallback matches `cci_v2_data` in
`drivers/i2c/busses/i2c-qcom-cci.c` -> **the CCI I2C bus can bind**. The sensors
will talk over this path. So at least one layer is ready.

### Clocks are ready, `camcc` is not needed

`gcc-sm6225.c` defines every camera clock: `CAMSS_TOP_AHB, CAMSS_AXI,
CAMSS_NRT_AXI, CAMSS_RT_AXI, CCI_0, CCI_CLK_SRC, CPHY_0/1/2, CSI0/1/2 PHYTIMER,
MCLK0..3, TFE_0..2, OPE_AHB, OPE`.

SM6225 provides its camera clocks **through GCC** (no separate
`camcc-sm6225.c` like on sm6350/sm7150 is required). This significantly reduces
the work.

### wl2866d was ported

Commit 43 added the driver, commit 44 the DT node:

```dts
wl2866d: pmic@28 {
	compatible = "willsemi,wl2866d";
	reg = <0x28>;
	enable-gpios = <&tlmm 26 GPIO_ACTIVE_HIGH>;
	regulators {
		wl2866d_dvdd1 { ... regulator-always-on; };   /* 1.2 V */
		wl2866d_dvdd2 { ... regulator-always-on; };   /* 1.05 V */
		wl2866d_avdd1 { ... regulator-always-on; };   /* 2.8 V */
		wl2866d_avdd2 { ... regulator-always-on; };   /* 2.8 V */
	};
};
```

The rails are `always-on`: the sensors do reference them now, but no rail is
ever switched between captures, so a rail shared by two modules cannot be
handled per module. Splitting that properly needs a supply consumer per rail
and was left alone.

### Flash LED — Kinetic KTD2691 on CCI1

It is not a PMIC peripheral at all. The LED driver sits on a camera I2C bus as
a KTD2691 at 7-bit address `0x64`, which is why the merged vendor DT contains
no `qcom,spmi-flash-led` node. A driver was written for it
(`drivers/leds/flash/leds-ktd2691.c`, commit `529cfda5a524`).

- Torch: 46 steps, `(code + 1) * 376 / 128` mA per the datasheet. The board
  declares `led-max-microamp = <132000>` (vendor code `0x2c`), so the top step
  is about 135 mA.
- The first version scaled against the chip's full 376 mA range and drove 2.8x
  the vendor current at maximum brightness. That was corrected to scale against
  the declared maximum.
- Flash: 504 mA for 200 ms, deliberately below the vendor's 1019 mA / 1000 ms.
- Only registration and the torch step table were verified. The LED has not
  been fired.

### The modules and their accessories

| Part | Bus / address | Notes |
|---|---|---|
| S5KJN1 (rear main) | CCI0 `0x10` | 4 data lanes, 700 MHz link, MCLK0 24 MHz |
| S5K3L6 (front) | CCI1 `0x10` | 2 data lanes, 537.5/600/625 MHz, MCLK1 19.2 MHz |
| OV08D10 (ultra wide) | CCI1 `0x36` | 2 data lanes, 720/360 MHz, MCLK2 19.2 MHz |
| GC02M1 (macro) | CCI0 `0x37` | 1 data lane, 336 MHz, MCLK3 19.2 MHz |
| GT9764 (VAF) | CCI0 `0x0c` | driven through `dw9719` in DW9800K mode |
| 24C256 (rear EEPROM) | CCI0 `0x51` | `atmel,24c256`, 32 KiB |
| KTD2691 (flash) | CCI1 `0x64` | torch and flash LED |

The VAF supply is a `regulator-fixed` on TLMM101 at 1.8-2.8 V, not a PM8008
regulator: the vendor DT turns the PM8008 nodes off, and they do not answer on
I2C. The lens parks at the vendor's initial DAC value of 367, which is what
untouched applications get.

Mounting: the rear main and the front module are both turned 90 degrees
counter-clockwise against the phone body (`rotation = <90>`), and the ultra
wide has its pixel array the other way round (`rotation = <270>`). The front
module is `orientation = <0>` so that applications mirror its preview; the
other two are `<1>`.

---

## 5. Why it was left out of the initial port, and what changed

The 7.2 branch did add SM6225 to `camss.c`, but as `.version = CAMSS_2290`
with the QCM2290 CSIPHY lane table, and it was left out of the port: without
the CSIPHY lane table, the AXI clock rates or a working GPLL10 the profile
would have bound and then failed at the first stream, which is harder to
diagnose than a compatible that does not bind at all.

The reference port for the same SoC (Motorola fogona, SD680) showed what was
missing and the profile was rebuilt on top of it. The prediction held: the
first build bound and produced 12 video nodes immediately, then failed at
STREAMON with `-EBUSY`, and needed the PLL work before a frame came out.

---

## 6. Work to do (small to large)

### Stage 0 — measurement / inventory (DONE)

1. Which sensor is fitted: answered by the vendor kernel log
   (`Probe success,slot:N,slave_addr:0xXX`) — S5KJN1 rear, S5K3L6 front,
   OV08A10 ultra wide, GC02M1 macro. See section 2.
2. Flash LED: still undetermined; no `qcom,spmi-flash-led` node exists in the
   vendor DT.

### Stage 1 — CCI + sensor probe (DONE for rear main, front and ultra wide)

3. CCI child nodes: rear main (CCI0 `0x10`), front (CCI1 `0x10`), ultra wide
   (CCI1 `0x36`), actuator (CCI0 `0x0c`) and the rear main EEPROM (CCI0 `0x51`).
4. MCLK pinctrl states: added, all four.
5. VAF actuator and `cam_vaf_2p8`: **added**.
6. `wl2866d` rails are wired and still `always-on`.
7. Sensor driver in defconfig: `CONFIG_VIDEO_S5KJN1=y`,
   `CONFIG_VIDEO_S5K3L6=y`, `CONFIG_VIDEO_OV08D10=y`, `CONFIG_VIDEO_DW9719=y`,
   `CONFIG_EEPROM_AT24=y`, `CONFIG_LEDS_KTD2691=y`, `CONFIG_RESET_GPIO=y`.
8. `media-ctl` shows the subdev topology.

### Stage 2 — CAMSS SM6225 profile (DONE)

9. `csiphy_res_6225`, `csid_res_6225`, `vfe_res_6225`, `icc_res_6225` and
   `sm6225_resources` are in `camss.c`. The TFE really is `vfe_ops_340`, the
   CSIPHY is the SM8250 v1.2.1 core, and CAMSS ICC paths are enough — the
   vendor CPAS layer is not needed for a single sensor RDI capture.
10. CSIPHY0 endpoint added and connected to the sensor endpoint.
11. `status = "okay"`, OPP table verified and voted through the MX/CX domains.

### Stage 3 — userspace (next)

12. Bring up the V4L2 pipeline with `v4l2-ctl`/`media-ctl` and capture a single
    frame. **DONE** — that is how the first frame was validated.
13. libcamera + `libcamera-tools`, or an application talking V4L2 directly.
14. There is no ISP/3A — CAMSS delivers raw Bayer, so colour processing has to
    happen in userspace. For a "take a photo" goal that is a separate project of
    its own.

### Stage 4 — remaining sensors (DONE except the macro)

15. **DONE, except the macro** — the S5K3L6 driver was written for this port
    from Vincent Cloutier's RFC series, changed to accept 19.2/24/25 MHz MCLK
    and to compute the PLL multiplier from the link frequency instead of
    carrying a per-mode constant. OV08D10 and OV13B10 already exist upstream.
    The GC02M1 driver was ported and probes, but no frame ever leaves it; the
    work is parked in `sources/tapas-macro-wip/`.
16. **DONE** — CSIPHY endpoints for CSIPHY0 (rear main), CSIPHY1 (ultra wide)
    and CSIPHY2 (front). The CSI lane mux on GPIO 100 is driven high by a
    gpio-hog. Mainline CAMSS has no mux model, so the ultra wide and the macro
    cannot both be described at once, which is one of the macro blockers.
17. **DONE** — rear main EEPROM (`atmel,24c256`, 32 KiB proven by the address
    wrap-around), autofocus (GT9764 through `dw9719`, `focus_absolute` 0..1023,
    parked at 367 at boot) and flash (KTD2691).

### Known gap in the capture path

The RDI write masters are programmed frame based, so the stride is derived from
the line length and a larger `bytesperline` from userspace is ignored. Frames
are correct, but a GPU importing the buffer has to copy them to a 64-byte
aligned pitch. The reference port switches the RDI path to line based
programming for this; that has not been done here.

---

## 7. Realistic assessment

| Stage | Difficulty | State |
|---|---|---|
| 0 — inventory | Easy | done |
| 1 — CCI + sensors | Medium | done for rear main, front and ultra wide |
| 2 — CAMSS profile | **Hard** | done; the PLL was the hard part |
| 3 — userspace | Medium | debayered preview works; autofocus open |
| 4 — remaining sensors | Medium each | done except the macro module |
| 5 — ISP/3A | **Very hard** | not started; libcamera's software ISP stands in |

The CPAS worry turned out not to matter for a single sensor RDI capture: the
TFE writes to memory through the SMMU and the ICC paths, and nothing in the
graph needs a CPAS node.

---

## 8. File map

| Path | Purpose |
|---|---|
| `drivers/media/platform/qcom/camss/camss.c` | SM6225 profile goes here |
| `drivers/media/platform/qcom/camss/camss-vfe-340.c` | TFE 340 hw_ops (present) |
| `drivers/i2c/busses/i2c-qcom-cci.c` | CCI (`cci_v2_data`, msm8996 fallback) |
| `drivers/media/i2c/{s5kjn1,ov08d10,ov13b10,ov2680}.c` | upstream sensor drivers |
| `drivers/media/i2c/s5k3l6.c` | front camera, written for this port |
| `drivers/media/i2c/dw9719.c` | VAF, with the GT9764 compatible added |
| `drivers/leds/flash/leds-ktd2691.c` | flash LED |
| `arch/arm64/boot/dts/qcom/sm6225.dtsi` | `camss@5c11000`, `cci@5c1b000` nodes |
| `arch/arm64/boot/dts/qcom/sm6225-xiaomi-tapas.dts` | sensor/EEPROM/actuator/flash nodes go here |
| `drivers/regulator/wl2866d-regulator.c` | camera PMIC (commit 43) |
| `drivers/leds/flash/leds-qcom-flash.c` | flash LED (`qcom,spmi-flash-led`) |
| `arch/arm64/configs/sm6225_defconfig` | `CONFIG_VIDEO_*` sensor symbols |

---

## 9. Forensic sources

The vendor device trees were decompiled once and checked in under
`sources/forensics/`, so nothing here depends on a scratch directory any more.
`images/` on the build machine holds the originals.

| Path | Contents |
|---|---|
| `sources/forensics/merged-fdt.dts` | 16 098 lines, the merged Tapas DT |
| `sources/forensics/tapas-overlay.dts` | 3 533 lines, the Tapas overlay (camera nodes live here) |
| `sources/forensics/base-soc.dts` | the base Khaje/SM6225 SoC DT |
| `images/dtbo.img` | 49 overlays; **entry 45** = tapas (`board-id 20022,0`, `msm-id 0x206`) |
| `images/vendor_boot.img` | embeds the base SoC DT |
| `/mnt/vendor`, `/mnt/vdlkm` | ro loop mounts; `camera.ko`, `leds-qti-flash.ko` |

---

## 10. Constraints / notes

- Raw frame capture, the sensor probe and the topology above were verified on
  the unit. Debayering, colour, exposure control and autofocus were not.
- The `wl2866d` rails are currently `always-on` — a deliberate temporary state
  that should be removed once all four modules have consumers.
- Sensor drivers: `s5kjn1`, `ov08d10`, `ov13b10` and `ov2680` are upstream;
  `s5k3l6` was written for this port; `gc02m1` and `hi259` have none. The parts
  actually fitted are S5KJN1, S5K3L6, OV08D10 and GC02M1.
- Autofocus works at the kernel level — `focus_absolute` moves the lens and the
  centre-of-frame sharpness changes — but libcamera 0.7.2's software IPA
  exposes no AF controls at all, so applications cannot drive it. The lens is
  parked at the vendor's initial position so that applications which never
  touch focus still get a usable image.
- Colour: `tools/go-chromatix2libcamera` converts the vendor chromatix blobs
  into libcamera tuning files, installed as
  `/usr/share/libcamera/ipa/simple/{s5kjn1,s5k3l6,ov08d10}.yaml`. Only
  `BlackLevel`, `Awb`, `Ccm`, `Adjust` and `Agc` load in libcamera 0.7.2;
  `Lsc`, `Denoise`, `Sharpen` and `Af` make the IPA fail to initialise.
- The rear main sensor is driven over the same pipeline as the others, so
  selecting the wrong pixel format fails loudly: `pgAA` is the packed GRBG10
  one that matches `SGRBG10_1X10`, and `BG10` is BGGR and returns `-EPIPE`.
