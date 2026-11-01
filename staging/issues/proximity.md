# Tapas — proximity sensor (tmd2755)

**Status:** PARTIAL · the sensor is visible and produces data but never reports `NEAR`
**Last updated:** 2026-10-31 · kernel `7.3.0-sm6225-upstream+`, branch `sm6225`

---

## 1. Summary

There were two separate problems; one is solved.

| Problem | Status |
|---|---|
| "No proximity sensor" — the sensor was not visible at all | **FIXED** (systemd boot race) |
| The sensor is visible but never reports `NEAR` when something approaches | **OPEN** |

The remaining problem is not a hardware defect: the chip produces data and the
value moves in the right direction, but the number the DSP reports stays far
below the stock thresholds.

---

## 2. The solved part: "No proximity sensor"

### Root cause

`iio-sensor-proxy` scans for sensors **exactly once at startup**
(`iio-sensor-proxy.c:126 find_sensors()`); afterwards it only listens for udev
`add`/`remove` actions (`sensor_changes()`; `change` is ignored). The
`fastrpc-adsp` misc device never emits a fresh `add` at runtime, so a failed
discovery is **never retried**.

Meanwhile `hexagonrpcd` was starting about 48 seconds later, because it is
pulled in by `WantedBy=graphical.target`. On the libssc side,
`ssc_proximity_discover()` gives up after 30 seconds:

```
'registry' sensor unavailable after 30s, is hexagonrpcd running?
```

Measured timeline (2026-10-29 boot):

```
19:40:04  remoteproc1: adsp is now up
19:40:18  iio-sensor-proxy started
19:40:51  discovery gave up after 30 s
19:41:07  hexagonrpcd started       <- 48 s too late
```

Accelerometer, light and compass answered fast enough and survived; proximity
was dropped. The `HasProximity` D-Bus property is
`driver_type_exists(DRIVER_TYPE_PROXIMITY)`, which is why it read `false`.

### Fix (applied, verified)

`staging/device/usr/lib/systemd/system/iio-sensor-proxy.service.d/tapas.conf`
(installed at the same path by the package):

```ini
[Unit]
Wants=hexagonrpcd.service
After=hexagonrpcd.service

[Service]
ExecStartPre=/bin/sleep 5
```

`Wants`/`After` establish the ordering; the `sleep 5` covers the extra margin
needed because `hexagonrpcd` is `Type=simple` and emits no readiness
notification. Without the sleep the two start about 10 ms apart and proximity is
still lost — confirmed by the user ("Evet oldu").

In addition, old hand-written `/etc/systemd/system/*.service.d/tapas.conf` files
were shadowing the packaged `/usr/lib/...` drop-ins; they were removed.

### Verification

```
hexagonrpcd       ActiveEnterTimestamp  43.37 s
iio-sensor-proxy  ActiveEnterTimestamp  48.66 s  (+5.3 s)
HasAccelerometer: true, HasAmbientLight: true, HasProximity: true
monitor-sensor --all -> all four sensors listed
```

---

## 3. The open part: `NEAR` never triggers

### Observation

`iio-sensor-proxy` / `libssc` receive proximity as `on-change`, and
`ProximityNear: false` never changes. Placing an object over the top of the
phone makes no difference. The same hardware on Android reports `NEAR`
(`dumpsys sensorservice` -> tmd2755 prox 0x53/0x54, value `0.00` = NEAR).

### Raw values measured

The QMI TLV in the `ssccli --sensor=proximity -v` output was decoded by hand:

```
1A:06:08:<near>:10:<distance>:18:<accuracy>
```

- field 1 = near (0/1)
- field 2 = distance (the driver's `pdata`, the number compared against the thresholds)
- field 3 = accuracy (always 3)

Measurements:

| Condition | `distance` |
|---|---|
| No object | **12–15** |
| Object present (hand/object close to the sensor) | **15–17** |

The two sets overlap at 15. **The modulation is only ~3 counts.**

### Thresholds

Registry `tmd2755_platform.prox.fac_cal` (from the device, stock values):

```json
{"near_threshold":"95.0", "far_threshold":"50.0", "reconfig":"0.0",
 "crosstalk":"10.0", "offset":"0.0", "near_diff":"0.0", "far_diff":"0.0"}
```

These are read as `PROXIMITY_DIST_FAR = 50`, `PROXIMITY_DIST_NEAR = 95` (same
convention as `drivers/iio/proximity`: a smaller value means closer). But the
number the DSP produces is in the 12–17 range, so it never reaches 95 and no
threshold pair can separate the two states.

### Facts cross-checked

- **The value moves in the right direction** (12–15 -> 15–17 as the object
  approaches). Polarity is not inverted.
- **Independent of the threshold:** the same raw values are read with 95/50, so
  the gain does not depend on the threshold.
- **The ALS on the same chip is fine:** 0 lux when covered, 143.8 lux in
  daylight. So I2C, the power rails (`/pmic/client/sensor_vdd`,
  `sensor_vddio`) and the DSP path are all healthy. Only the **prox IR emitter /
  ADC path is weak**.
- **The payload is byte-identical to Android:** the 299 registry entries, the 70
  config JSONs and the `adsp.mdt` md5s all match. This is runtime behaviour, not
  a data problem.

### Threshold experiments tried (all failed)

| Experiment | Result | Valid |
|---|---|---|
| near=5 / far=2 | `NEAR` at rest (meaningless, count is >= 5) | Partially |
| near=1 / far=0 + `systemctl restart hexagonrpcd` | Still `FAR` | **Invalid** — the DSP reads the registry only at ADSP boot |
| near=5 / far=2 + reboot | `NEAR` with no hand present | Valid but low information value |
| near=200 / far=150 + reboot | `FAR` even with a hand present | Valid, failed |
| near=1 / far=0 + `restart` | `FAR` | **Invalid** (same reason) |

The thresholds were afterwards restored to the stock 95/50; backup at
`/root/prox.fac_cal.default`, helper `/root/setprox.py <near> <far>`.

> **Warning:** to force the registry to be re-read, `remoteproc1` stop/start was
> **tried and it crashed the device.** It must never be done again. A normal
> reboot is the only way.

### Registry parameters

```
tmd2755_platform.proxconfig = {0:1, 1:2816, 2:32, 3:10, 4:64, 5:3, 6:1, 7:100.0}
tmd2755_platform.config      = bus_type 0, bus_instance 1, slave_config 0x39 (57),
                              400 kHz, dri_irq_num 35, irq_pull_type 2,
                              irq_is_chip_pin 1, irq_trigger_type 4,
                              num_rail 2, rail_on_state 2,
                              vdd /pmic/client/sensor_vdd, vddio /pmic/client/sensor_vddio
tmd2755_platform.coefficient = {20.437, -96.863, 4843.148, 1.0, -0.487, 87413.87,
                                1.0, -0.253, 8.8, 15432.25, 200.0, 3500.0}
tmd2755.prox.config          = is_dri 0, hw_id 1, res_idx 0, sync_stream 0
```

`reconfig`, `offset`, `near_diff` and `far_diff` inside `fac_cal` are **all 0**
and match the defaults in `sensors/config/holi_tmd2755_0.json` exactly
-> this device was **not factory-calibrated for proximity**. Android works with
the same uncalibrated data and still gets `NEAR`, so the missing calibration is
not sufficient as an explanation on its own.

### Driver vocabulary from the firmware

The `adsp.b*` segments were concatenated and scanned with `strings`:

```
sns_tmd2755_sensor.c: TMD2755 Registry read event for group registry_proxconf
                      received c[0]:%u c[4]:%u c[5]:%u
sns_tmd2755_sensor.c: Registry read version %d,%d,%d,%d fac_cal proximity
                      near_thresh:%d far_thresh:%d reconfig:%d
sns_tmd2755_hal_island.c: pdata=%d, offset_l=%d, offset_h=%d
sns_tmd2755_hal_island.c: prox_high_thresh=%d, prox_low_thresh=%d
sns_tmd2755_hal_island.c: might have contamination issue
                          state->far_threshold=%d, state->near_threshold=%d
sns_tmd2755_sensor_instance.c: ps 3cm calibration start. / ps ct calibration start.
                               / calibration failed
TMD2755_POFFSETH_REG / POFFSETL_REG
```

From this: `distance` is the driver's `pdata`, compared directly against the
thresholds; there is also a `POFFSET` (prox offset) register and a "3cm /
crosstalk calibration" flow. So the low reading most likely comes from a wrong
**POFFSET** value — which is exactly what the missing factory calibration would
have written.

---

## 4. Next steps

### Step 1 — does the DSP read the `proxconfig` group at all? (cheap, decisive)

Change `c[1]` in `tmd2755_platform.proxconfig` from **2816 to 1408** and reboot.
Then measure the raw `distance` again with `ssccli`.

- If the value changes -> the group is honoured and tuning through these
  parameters is possible.
- If it does not change -> the DSP ignores the group and the problem lies in the
  driver's own defaults.

Cost: roughly a 2 minute reboot. Very high information per experiment.

### Step 2 — understand the `POFFSET` register

The firmware references `TMD2755_POFFSETH_REG` / `POFFSETL_REG`. `proxconfig`
`c[2]` (=32) and `c[3]` (=10) may be parts of that offset. The vendor `tmd2755`
driver (amstaos / vendor kernel) should be located and its register map
extracted.

### Step 3 — look at Android's calibration data

Since proximity works on Android, either Android uses a different threshold with
the same raw values, or it performs a calibration at runtime. Check whether the
`persist` partition holds a tmd2755 calibration file.

### Step 4 — replicate the vendor calibration flow if necessary

The firmware contains "ps 3cm calibration" and "ps ct calibration" (crosstalk)
flows. These may be triggered by a QMI command; investigate whether they can be
triggered through `libssc`/`ssccli`. If they can, `POFFSET` can be written with
the correct value.

---

## 5. Paths that definitively **do not work** (do not retry)

- Changing the threshold values — the modulation is 3 counts, no pair separates
  the states.
- Forcing the registry to be re-read with `systemctl restart hexagonrpcd` — the
  DSP caches it in RAM.
- `remoteproc1` stop/start — **crashes the device**.
- A udev knob like `ACCEL_MOUNT_MATRIX` — no such mechanism exists for
  proximity; `drv-ssc-proximity.c` only receives a resolved `gboolean near` and
  accepts no matrix or threshold.
- Fixing it in `iio-sensor-proxy` — the sensor reports `FAR` from the DSP; the
  proxy only relays it.

---

## 6. File map

| Path | Purpose |
|---|---|
| `/usr/share/qcom/sm6225/Xiaomi/tapas/sensors/registry/tmd2755_platform.prox.fac_cal` | thresholds, offset, crosstalk |
| `.../registry/tmd2755_platform.proxconfig` | driver prox configuration (`c[0]`..`c[7]`) |
| `.../registry/tmd2755_platform.coefficient` | conversion coefficients |
| `.../registry/tmd2755_platform.config` | bus, address, IRQ, power rails |
| `.../registry/tmd2755.prox.config` | `is_dri`, `hw_id`, `res_idx`, `sync_stream` |
| `.../sensors/config/holi_tmd2755_0.json` | vendor defaults (identical to the registry) |
| `adsp.mbn` (`/lib/firmware/qcom/sm6225/XIAOMI/TAPAS/adsp.b*`) | the `sns_tmd2755*` driver is embedded here |
| `staging/device/usr/lib/systemd/system/iio-sensor-proxy.service.d/tapas.conf` | boot race fix |

---

## 7. Constraints / notes

- A registry change only takes effect after a **reboot**.
- `ssccli` stdout is block-buffered; use
  `timeout -s INT 6 ssccli --sensor=proximity -v > /tmp/f.txt 2>&1` and `grep`
  the file afterwards.
- `monitor-sensor` must run as root (the polkit `allow_active` rule rejects SSH
  sessions).
- `iio-sensor-proxy` 3.9 has **no gyroscope driver**; gyro will never appear
  (by design, not the subject of this document).
- The measurements in this document were taken on the device, but **no fix has
  been applied**.
