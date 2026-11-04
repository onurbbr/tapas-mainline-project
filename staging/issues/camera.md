# Tapas — camera

**Status:** OPEN · no stage of it works · largest work item
**Last updated:** 2026-10-31 · kernel `7.3.0-sm6225-upstream+`, branch `sm6225`
**Related commits:** 44 (`cd989c720f3d` — wl2866d camera PMIC description),
43 (`d81b1c7cc4b8` — wl2866d driver)

---

## 1. Summary

The camera does not work yet, and the gaps are layered:

1. **Kernel:** mainline CAMSS has no SM6225 support, and the CPAS layer the
   vendor stack relies on has no mainline model at all. Without it there is
   no capture path, no matter how well the sensors are described.
2. **Device tree:** the camera bus and the rear main sensor are now
   described, which is what makes the sensor probe work. The auxiliary
   modules are not described yet because mainline has no driver for the parts
   that are actually fitted.
3. **Userspace:** the V4L2 + libcamera side was never set up.

What works today: the Camera Control Interface is up and the rear main
sensor (s5kjn1) probes, reads its chip ID and registers a V4L2 subdevice.
That confirms the bus, the master clock, the reset line and the rail
assignment.

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

From the vendor DT (`/tmp/work/tapas.dts`) and the `/vendor`, `/vendor_dlkm`
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

### No SM6225 in `camss.c`

```
$ grep -c sm6225 drivers/media/platform/qcom/camss/camss.c
0
```

Existing profiles: `CAMSS_8x16, 8x39, 8x53, 8x96, 660, 670, 845, 2290, 6150,
6350, 8250, 7280, 8280xp, 8300, 8550, 8650, 8775, qcs8300, x1e80100`.

### But the building blocks exist

- `drivers/media/platform/qcom/camss/camss-vfe-340.c` — the **TFE 340** hw_ops
  is present in mainline.
- `qcm2290_resources` (`.version = CAMSS_2290`) uses those TFE ops, and
  `vfe_res_2290` defines the `camnoc_rt_axi` / `camnoc_nrt_axi` clocks.
- SM6225 also belongs to the bengal family, so this profile is a **close**
  starting point.

### The `camss` node in our dtsi is dead

`arch/arm64/boot/dts/qcom/sm6225.dtsi` (~line 3533):

```dts
camss: camss@5c11000 {
	compatible = "qcom,sm6225-camss";       /* no driver matches */
	reg = ... top, csid0-2, csiphy0-2, csitpg0-1, vfe0-2 ...;
	reg-names = ...;
	clocks = ... 20 GCC camera clocks ...;
	interrupts = ...;
	interconnects = ... ahb, hf_mnoc, sf_mnoc ...;
	iommus = <&apps_smmu 0x400/0x800/0x820/0x840>;
	power-domains = <&rpmpd SM6115_VDDMX>, <&rpmpd SM6115_VDDCX>, <&gcc GCC_CAMSS_TOP_GDSC>;
	operating-points-v2 = <&camss_opp_table>;
	vdd-csiphy-1p2-supply = <&pm6125_l4>;
	vdd-csiphy-1p8-supply = <&pm6125_l18>;
	status = "disabled";
	ports { port@0 {} port@1 {} port@2 {} };   /* NO endpoints */
};
```

Three problems:

1. `"qcom,sm6225-camss"` is not in `camss.c` and there is no fallback
   compatible -> **it will never bind**.
2. `status = "disabled"`, and the Tapas DTS has **no** `&camss` override.
3. `port@0/1/2` are empty and have no endpoints -> the sensor connections are
   not described.

On the other hand the reg/clock/interrupt/IOMMU map in the node **is complete
and usable**; once an SM6225 profile is added to CAMSS this node works as is.

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

The rails are `always-on` because there is **no consumer yet** (there are no
sensor nodes). Once the sensors are wired up, `always-on` should be removed and
real `*-supply` references given.

### Flash LED — undetermined

- The mainline driver is `drivers/leds/flash/leds-qcom-flash.c`, compatible
  **`qcom,spmi-flash-led`**.
- The vendor DT has **no** `qcom,spmi-flash-led` node, only `qcom,camera-flash`.
- The vendor side works through `leds-qti-flash.ko`.
- Which PMIC carries the LED **has not been determined**. Physical PMIC
  inventory: `qcom,pm6125` (15 references), `qcom,pm8008` (47 references),
  `qcom,pm8941` (1, RTC only). There is no pmi632/pm6150l-style flash node.

Flash should be handled as a separate sub-task once the camera works.

---

## 5. Why it was left out of the initial port

The 7.2 branch did add SM6225 to `camss.c`:

```
csiphy_res_sm6225, csid_res_sm6225, vfe_res_sm6225, icc_res_sm6225
sm6225_resources { .version = CAMSS_2290, ... }
```

But `vfe_res_sm6225` models the three SM6225 **TFE** blocks as `vfe_ops_340`
VFE340 instances using the `camnoc_rt_axi`/`camnoc_nrt_axi` clocks. Since
mainline has no CPAS layer this mapping was **speculative**: it compiles, but
on real hardware the data path setup would be incomplete. That is why it was
not carried over.

That decision is defensible, but the `qcom,sm6225-camss` compatible in the dtsi
was left as an **open loose end**: nothing binds it and nothing consumes it.

---

## 6. Work to do (small to large)

### Stage 0 — measurement / inventory (easy)

1. Determine which sensor is fitted. Either probe over CCI (address scan while
   the sensors are held in reset) or infer it from the `/vendor` calibration
   file names (`s5kjn1` / `ov08d10` / ... calibration binaries).
2. Determine which PMIC carries the flash LED (vendor `leds-qti-flash.ko`
   symbols, PMIC register map).

### Stage 1 — CCI + sensor probe (medium)

3. Add the CCI child nodes to the Tapas DTS: sensor, EEPROM and actuator nodes
   under `&cci_i2c0` / `&cci_i2c1` (address, reset, MCLK, rails).
4. Add the MCLK pinctrl states (TLMM 20/21/27/28, function `cam_mclk`).
5. Add the `cam_vaf_2p8` regulator-fixed (TLMM 101) and the VAF actuator.
6. Remove `always-on` from the `wl2866d` rails and wire them to the sensors as
   `*-supply`.
7. Add the sensor drivers (`s5kjn1`, `ov08d10`, `ov13b10`, `ov2680`) to
   `sm6225_defconfig`.
8. Verify with `media-ctl` that the subdev topology appears (subdevs show up
   under CCI even without CAMSS).

This stage can be done **without CAMSS** and proves the sensors are reachable.

### Stage 2 — CAMSS SM6225 profile (hard)

9. Add `csiphy_res_sm6225`, `csid_res_sm6225`, `vfe_res_sm6225`,
   `icc_res_sm6225` and `sm6225_resources` to `camss.c`. The 7.2 attempt is a
   **reference**, but:
   - is TFE really `vfe_ops_340`? The register map must be verified,
   - CSIPHY v1.2.1 and CSID compatibility must be checked,
   - whether CAMSS ICC paths can substitute for what CPAS does (NOC/data path)
     must be **measured** — this is the largest risk.
10. Add port endpoints to the `camss` node in `sm6225.dtsi`
    (`camss_port0_in` <- sensor output, CSIPHY/CSID links).
11. Set `camss` `status = "okay"` and verify the OPP table.

### Stage 3 — userspace (medium to hard)

12. Bring up the V4L2 pipeline with `v4l2-ctl`/`media-ctl` and capture a single
    frame.
13. libcamera + `libcamera-tools` (only if the simple pipeline is supported) or
    an application talking V4L2 directly.
14. There is no ISP/3A — CAMSS delivers raw Bayer, so colour processing has to
    happen in userspace. For a "take a photo" goal that is a separate project of
    its own.

---

## 7. Realistic assessment

| Stage | Difficulty | Note |
|---|---|---|
| 0 — inventory | Easy | 1–2 days |
| 1 — CCI + sensor probe | Medium | Weeks; can be attempted without touching CAMSS |
| 2 — CAMSS profile | **Hard** | The CPAS gap is the real uncertainty |
| 3 — userspace + ISP | Hard | A separate project |

The biggest technical risk is **CPAS**. Mainline CAMSS does not model the vendor
CPAS layer. Whether TFE/OPE data paths work on SM6225 without it, and whether
upstream has a precedent, is not clear. That question should be answered before
starting Stage 2 — for example by comparing against a similar stack that runs
without CPAS, such as sm8250 or qcm2290.

---

## 8. File map

| Path | Purpose |
|---|---|
| `drivers/media/platform/qcom/camss/camss.c` | SM6225 profile goes here |
| `drivers/media/platform/qcom/camss/camss-vfe-340.c` | TFE 340 hw_ops (present) |
| `drivers/i2c/busses/i2c-qcom-cci.c` | CCI (`cci_v2_data`, msm8996 fallback) |
| `drivers/media/i2c/{s5kjn1,ov08d10,ov13b10,ov2680}.c` | existing sensor drivers |
| `arch/arm64/boot/dts/qcom/sm6225.dtsi` | `camss@5c11000`, `cci@5c1b000` nodes |
| `arch/arm64/boot/dts/qcom/sm6225-xiaomi-tapas.dts` | sensor/EEPROM/actuator/flash nodes go here |
| `drivers/regulator/wl2866d-regulator.c` | camera PMIC (commit 43) |
| `drivers/leds/flash/leds-qcom-flash.c` | flash LED (`qcom,spmi-flash-led`) |
| `arch/arm64/configs/sm6225_defconfig` | `CONFIG_VIDEO_*` sensor symbols |

---

## 9. Forensic sources (VM `ssh debian`)

| Path | Contents |
|---|---|
| `/home/onur/Projects/Debian/development/images/fdt` | merged Tapas DT |
| `.../dtbo.img` | 49 overlays; **entry45** = tapas (`board-id 20022,0`, `msm-id 0x206`) |
| `.../vendor_boot.img` | embeds the base Khaje/SM6225 SoC DT |
| `/tmp/work/fdt.dts` | 16 098 lines, readable DT |
| `/tmp/work/tapas.dts` | 3 533 lines, the Tapas overlay (camera nodes live here) |
| `/tmp/work/vb.dts` | base SoC DT |
| `/mnt/vendor`, `/mnt/vdlkm` | ro loop mounts; `camera.ko`, `leds-qti-flash.ko` |

---

## 10. Constraints / notes

- Nothing in this document was verified on hardware; the camera was **never
  exercised**.
- The `wl2866d` rails are currently `always-on` — a deliberate temporary state
  that should be removed once the camera works.
- The `camss` node in `sm6225.dtsi` is currently dead code; it was not deleted
  because it is a ready foundation for Stage 2.
- Sensor drivers are limited to those present in mainline (`s5kjn1`, `ov08d10`,
  `ov13b10`, `ov2680`); `s5k3l6`, `gc02m1` and `hi259` would need drivers
  written from scratch.
