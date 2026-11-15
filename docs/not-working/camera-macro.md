# Tapas — rear macro camera (GC02M1)

**Status: not working.** The sensor probes and answers on I2C, the graph
connects, but no frame ever reaches memory.

| | |
|---|---|
| Part | GalaxyCore GC02M1, 2 MP |
| Module | `m7_ofilm_gc02m1_macro_i` |
| I2C | CCI0, 7-bit `0x37` (vendor 8-bit `0x6e`) |
| Chip ID | `0x02e0` at register `0xf0` — **read successfully** |
| CSIPHY | 1, shared with the ultra wide module through a lane mux |
| MCLK | MCLK3, GPIO 28, 19.2 MHz |
| Reset | GPIO 68, active low |
| Enable | GPIO 99, must be **high** |
| Mux select | GPIO 100 |
| Lanes | 1 (2 tried, no difference) |
| Link frequency | 336 MHz |
| Driver | `gc02m0.c`, adapted from one that landed in armbian/linux-rockchip |

## What is proven

- The driver binds, reads the chip ID and publishes a 1600x1200
  `SRGGB10_1X10` format.
- The write path works: after `s_stream` the sensor reports `0x3e = 0x90`
  (streaming), and the init table reads back with the values that were written.
- The media graph is correct:
  `gc02m1 0-0037 -> msm_csiphy1 -> msm_csid0 -> msm_vfe0_rdi0 -> /dev/video0`,
  every link `ENABLED`, every pad `SRGGB10_1X10/1600x1200`.
- MCLK3 runs at 19.2 MHz, the PMIC rails are up, the reset line is owned by
  the driver and pulsed.

## What is not proven

That the sensor emits MIPI data at all. Every capture times out with zero
bytes, and the CSIPHY status registers stay at zero while it runs.

## Hypotheses that were eliminated

| Idea | Why it is out |
|---|---|
| The macro is really an OV2680 / OV5647 | Vendor probe log says `sensor_id 0x2e0`; the module file is `gc02m1` |
| Wrong I2C address | `0x37` answers with the right chip ID |
| Wrong lane position | `<0>`, `<1>`, `<3>` and `<2 3>` all tried; no change |
| 1-lane PHY problem | 2-lane tried; no change |
| Wrong PHY | Moved the sensor to CSIPHY0, which is proven with the rear main sensor; camss then failed to probe |
| GPIO 100 mux polarity | Both low and high tried with a correct link set |
| GPIO 99 is a mux select | With it low the sensor does not answer on I2C at all, so it is an enable |
| GPIO 68 reset ownership | Tried both as a hog and owned by the driver |
| AXI clock too slow | Removed the 19.2 MHz entry so the write path picks 150 MHz; frames still did not arrive |
| MIPI PLL arithmetic | Switched to the 19.2 MHz / 336 MHz set that is known to work on a sibling device; no change |
| Wrong `media-ctl` link | An enabled link to `msm_csid0` silently blocks a second one; fixed, still no data |

The board schematic shows the macro connector on `CSI1` lanes 2 and 3
(`CSI1_C1_LN2_P`, `CSI1_A2_LN2_M`, `CSI1_B2_LN3_P`, `CSI1_C2_LN3_M`), which
does not match any of the lane configurations that were tried successfully,
and does not match what the other modules on the same PHY use.

## Where the work is archived

The driver and device tree node were never committed: they live in the 7.3
tree's working history and in the notes of `working/camera.md`. Nothing about
this module is in the 7.4 tree.
