# tapas-mainline-project

Everything needed to run mainline Linux on the **Xiaomi Redmi Note 12 4G**
(codename **tapas**), apart from the kernel itself.

The kernel lives in its own tree: branch `sm6225` of
[onurbbr/linux](https://github.com/onurbbr/linux), based on Linux v7.3.

This repository holds the packaging scripts, the firmware staging tree and the
device integration files (ALSA UCM, udev rules, systemd drop-ins, docs).

---

## Device

| | |
|---|---|
| Marketing name | Xiaomi Redmi Note 12 4G |
| Model number | 23021RAAEG |
| Codename | `tapas` |
| SoC | Qualcomm Snapdragon 685 (SM6225, "Khaje") |
| SoC ID | `518` |
| DT `msm-id` | `<518 0x10000>` |
| DT `board-id` | `<0x20022 0>` |
| DT compatible | `xiaomi,tapas`, `qcom,sm6225` |
| Vendor hardware platform | `IDP` (debugfs `hardware_platform = 34`) |
| Bootloader | U-Boot, booting Debian from SD card |
| Storage layout | slot A = Android, slot B = Linux on SD card |

### Hardware

| Block | Part | Notes |
|---|---|---|
| Display | Xiaomi M7 38 0C 0A, 1080x2400 AMOLED | DSI, reset on TLMM 82 |
| Touchscreen | Focaltech FT3518/FT3519 | I2C 0x38, `edt-ft5x06` driver, AVDD switch on TLMM 36 |
| Audio codec | Qualcomm WCD9370 | SoundWire, RX/TX macros on LPASS |
| Speaker amp | Awinic AW87XXX | I2C 0x59, ACF firmware blob |
| Charger | TI BQ25890 (PN = 1 variant) | I2C 0x6a, reports detected USB type |
| USB-C PD | Richtek RT1711H | I2C 0x4e |
| Fuel gauge | SM5602 | I2C 0x71 |
| Charge pump | Southchip SC8551 | divider charger, I2C 0x66 |
| Battery auth | Maxim DS28E16 | 1-Wire on TLMM 108 |
| Camera PMIC | Willsemi WL2866D | I2C 0x28, enable on TLMM 26 |
| Vibration | PM6125 GPIO 8 | via `gpio-vibrator` |
| Storage | UFS | QMP UFS PHY |
| Wi-Fi/BT | WCN3950 (FastConnect 6100) | ath10k + `qca` BT firmware |

Cameras (four, all on CCI; the fitted module depends on the production batch):

| Role | Sensors seen in the field | CCI | CSIPHY | MCLK | Reset |
|---|---|---|---|---|---|
| Rear main | S5KJN1 | 0 | 0 | MCLK0 | TLMM 18 |
| Front | S5K3L6 / OV13B10 | 1 | 2 | MCLK1 | TLMM 24 |
| Rear ultra | OV08D10 | 1 | 1 | MCLK2 | TLMM 19 |
| Rear macro | GC02M1 / OV2680 / HI259 | 0 | 1 | MCLK3 | TLMM 68 |

Sensors are **not** on the AP's I2C/SPI. Their drivers live inside the ADSP
firmware as part of the Snapdragon Sensor Core; Linux only boots the ADSP,
maps `msm/adsp/sensor_pd` and talks QMI to service 400 over QRTR, with
`hexagonrpcd` providing the DSP's file access.

| Sensor | Part | Type |
|---|---|---|
| Accelerometer / gyro | Bosch BMI3x0 | SSC I2C bus 2, 0x68 |
| Magnetometer | QMC630x | SSC I2C bus 2, 0x2c |
| ALS / proximity | AMS TMD2755 | SSC I2C bus 1, 0x39 |
| SAR | Semtech SX932x | SSC I2C bus 1, 0x28 |

Note: the bus numbers above are the **DSP's own** I2C controllers, not the AP's
QUP instances.

---

## Repository layout

```
build.sh                  build the boot image / SD card
boot.cmd                  U-Boot boot script source
scripts/build-debs.sh     the package builder
scripts/build-image.sh    image builder

staging/firmware/         install tree, copied verbatim into firmware-xiaomi-tapas
  usr/lib/firmware/         ADSP/CDSP/modem, zap, IPA, ath10k, qca, venus, tplg

staging/device/           install tree, copied verbatim into device-xiaomi-tapas
  usr/lib/udev/rules.d/70-tapas-camera.rules
  usr/share/alsa/ucm2/Qualcomm/sm6225/tapas/
  usr/share/alsa/ucm2/conf.d/sm6225/Xiaomi-Redmi-Note-12-4G.conf
  usr/share/u-boot-menu/conf.d/tapas.conf

docs/                     one document per subsystem, with the detail
  README.md               index: one row per subsystem, with its status
  status.md               kernel trees, hardware tested, firmware notes
  audio.md  camera.md  video-decode.md
  proximity.md  voice-call.md  camera-macro.md  autofocus.md

sources/forensics/        vendor device trees, decompiled once and kept here
  merged-fdt.dts          the merged Tapas DT, 16 098 lines
  tapas-overlay.dts       the Tapas overlay, 3 533 lines
  base-soc.dts            the base Khaje/SM6225 SoC DT
```

`staging/kernel/`, `debs/` and `images/` are **not** tracked; see `.gitignore`.
Kernel build products are copied into `staging/kernel/` before packaging.

---

## Packages built

| Package | Contents |
|---|---|
| `firmware-xiaomi-tapas` | the whole `staging/firmware/usr` tree, plus an initramfs hook |
| `device-xiaomi-tapas` | UCM profiles, udev rules, boot menu config |
| `linux-image-tapas` | `Image`, DTB, config, initramfs |
| `linux-modules-tapas` | kernel modules |

`firmware-xiaomi-tapas` depends on `qrtr-tools`, `rmtfs`, `tqftpserv`,
`protection-domain-mapper` and `libssc2`.
`device-xiaomi-tapas` depends on `alsa-ucm-conf`, `qcom-phone-utils`,
`u-boot-menu` and the three packages above.

### Building

```
bash scripts/build-debs.sh all        # or: kernel | modules | image | firmware | device
```

Output lands in `debs/`.

---

## Firmware layout and hexagonrpcd

`hexagonrpcd` builds a virtual filesystem for the DSP from a prefix directory
(`-R`, or the `hexagonrpcd_fw_dir` environment variable). Debian's wrapper
defaults to `/var/lib/droid-juicer/sensors`, so a drop-in points it at
`/usr/share/qcom/sm6225/Xiaomi/tapas` (`hexagonrpcd-tapas.conf`).

The mapping, per the `hexagonrpcd` man page:

| hexagonrpcd | Android source |
|---|---|
| `acdb` | `/vendor/etc/acdbdata` |
| `dsp` | `/vendor/dsp` |
| `sensors/config` | `/vendor/etc/sensors/config` |
| `sensors/registry` | `/mnt/vendor/persist/sensors/registry/registry` |
| `sensors/sns_reg.conf` | `/vendor/etc/sensors/sns_reg_config` |
| `socinfo` | `/sys/devices/soc0` |

The vendor component **must** be capitalised `Xiaomi`; `hexagonrpcd` derives the
path from the first word of `/proc/device-tree/model`.

`acdb`, `sns_reg_config` and `registry` are mandatory for the virtual
filesystem. `sns_reg.conf` must **not** contain
`property=ro.boot.hwname=...` -- there is no Android property service on
Debian, and the DSP asserts if it cannot resolve it.

---

## Working around the sensor boot race

`iio-sensor-proxy` probes sensors exactly once at startup and never retries.
`hexagonrpcd` starts much later, so the proxy must be ordered after it:

```ini
[Unit]
Wants=hexagonrpcd.service
After=hexagonrpcd.service

[Service]
ExecStartPre=/bin/sleep 5
```

This is shipped as `iio-sensor-proxy-tapas.conf`. Without the `sleep 5` the two
start ~10 ms apart and proximity is lost for the whole session.

---

## Status

See `docs/README.md` for the per-topic detail and `docs/status.md` for the
long version. Short version:

| Topic | Status |
|---|---|
| Boot, display, touch, UFS, haptics, charging | working |
| Audio playback | working: speaker, headphones on jack, earpiece |
| Microphone | working: handset and top mic together, headset boom on jack |
| Sensors: accelerometer, ambient light, compass | working |
| Camera | rear main, front and ultra wide capture RAW frames |
| Camera lens | `focus_absolute` moves the lens; no autofocus in userspace |
| Video decode | working: H.264, HEVC and VP9 through iris |
| Proximity | visible, but never reports `NEAR` |
| Rear macro camera | sensor probes, no frames |
| Voice call | parked; the DSP rejects the voice graph |

Two kernel trees exist. `Kernels/linux-7.4`, branch `sm6225-tapas`, based on
v7.4-rc1, is the one to work on from now on; everything above was last
measured with a 7.3 image, and the 7.4 tree builds but has not been installed
on the device yet. `Kernels/linux-7.3`, branch `sm6225`, is frozen.

Haptics are binary on/off: the enable GPIO is the only control, both in the
vendor driver and in `gpio-vibrator`, so there is no amplitude modulation to
port.

---

## Firmware and calibration data

`staging/firmware/` contains blobs extracted from the device's own vendor
partition (ADSP/CDSP/modem firmware, DSP libraries, ACDB calibration databases,
SSC registry). They are redistributed here only to make this specific device
work, and remain the property of their respective owners.
