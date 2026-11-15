# Uncommitted work that was lost with the revert

These changes were on top of the committed PoC when the work was parked. They
were discarded with `git checkout` before the commits were reverted, so the
code below is the record of them; re-apply by hand.

All three were compiled and tested. None of them fixed the failure:
`GRAPH_START` still answered `error[1001002] 1`, and after the sub-graph list
fix the error moved back to `GRAPH_PREPARE` (`error[1001001] 2`).

## 1. Sub-graph lists read from the open payload

Hard-coded lists were the source of a whole class of "list does not match the
blob" failures (a bare DSP error with no hint). The fix reads them back from
`SUB_GRAPH_CONFIG` in the open payload.

Two traps, both hit in practice:

* The payload is not `{count, id...}`. It is
  `{count, (sg_id, num_props, (prop_id, size, value)*)*}`, so the ids have to
  be picked out while walking each sub-graph's property list.
* `param_size` is in **bytes**, so the property value is
  `DIV_ROUND_UP(size, 4)` words.

```c
#define VOICE_POC_MAX_SGS	8

static u32 voice_poc_rx_sgs[VOICE_POC_MAX_SGS + 1];
static u32 voice_poc_tx_sgs[VOICE_POC_MAX_SGS + 1];

static int voice_poc_load_sgs(struct device *dev, const char *name, u32 *sgs)
{
	const struct firmware *fw;
	size_t off = 0;
	int ret = -EINVAL;

	if (request_firmware(&fw, name, dev))
		return -ENOENT;

	while (off + sizeof(struct apm_module_param_data) <= fw->size) {
		const struct apm_module_param_data *p = (void *)(fw->data + off);
		size_t len = ALIGN(sizeof(*p) + p->param_size, 8);

		if (!p->param_size || off + len > fw->size)
			break;
		if (p->param_id == APM_PARAM_ID_SUB_GRAPH_CONFIG) {
			const u32 *w = (const u32 *)(p + 1);
			size_t words = p->param_size / sizeof(u32);
			size_t i = 1;
			u32 n, k;

			n = w[0];
			if (!n || n > VOICE_POC_MAX_SGS || i + 2 * n > words)
				break;
			sgs[0] = n;
			for (k = 0; k < n; k++) {
				u32 nprops, j;

				if (i + 2 > words)
					goto out;
				sgs[k + 1] = w[i];
				nprops = w[i + 1];
				i += 2;
				for (j = 0; j < nprops; j++) {
					u32 nwords;

					if (i + 2 > words)
						goto out;
					nwords = DIV_ROUND_UP(w[i + 1], sizeof(u32));
					i += 2 + nwords;
				}
			}
			ret = 0;
			break;
		}
		off += len;
	}
out:
	release_firmware(fw);
	if (ret)
		dev_err(dev, "voice-poc: no usable sub-graph list in %s\n", name);
	return ret;
}
```

The `VOICE_POC_SG` macro then takes the count from element 0:

```c
#define VOICE_POC_SG(apm, op, sgs) \
	voice_poc_sg_cmd(apm, op, (sgs) + 1, (sgs)[0] * sizeof((sgs)[0]))
```

and `voice_poc_start()` loads both lists right before the first `GRAPH_OPEN`:

```c
	rc = voice_poc_load_sgs(apm->dev, "qcom/sm6225/voice-rx5-open.bin",
				voice_poc_rx_sgs);
	if (rc)
		return rc;
	rc = voice_poc_load_sgs(apm->dev, "qcom/sm6225/voice-tx-open.bin",
				voice_poc_tx_sgs);
	if (rc)
		return rc;
```

Verified parse of `vg-stock/voice-rx5-open.bin`:
`count 4, ids 0xb000002a 0xb0000040 0xb0000041 0xb0000044` — 54 words, no
padding left over.

## 2. Media format for the CODEC DMA sink in the voice graph

Nothing configures that sink: the ALSA topology only ever sets up the playback
graph's own instance, and `GRAPH_START` rejects a hardware endpoint with no
format. The four parameters are the ones
`audioreach_codec_dma_set_media_format()` sends, in the same order and with
the same block sizes.

```c
#define VOICE_POC_SINK_INSTANCE	0x43b3

static void voice_poc_param(u8 **p, u32 instance, u32 param, const void *pl,
			    u32 size)
{
	struct apm_module_param_data *hdr = (void *)*p;

	hdr->module_instance_id = instance;
	hdr->param_id = param;
	hdr->param_size = size;
	hdr->error_code = 0;
	memcpy(*p + sizeof(*hdr), pl, size);
	*p += ALIGN(sizeof(*hdr) + size, 8);
}

static int voice_poc_configure_sink(struct q6apm *apm)
{
	/* 48 kHz, 16 bit, two channels, DATA_FORMAT_FIXED_POINT. */
	struct {
		u32 sample_rate;
		u16 bit_width;
		u16 num_channels;
		u32 data_format;
	} __packed mf = { 48000, 16, 2, 1 };
	/* RX_CODEC_DMA_RX_0 is on the RXTX LPAIF, interface index 1. */
	struct {
		u32 lpaif_type;
		u32 intf_index;
		u32 active_channels_mask;
	} __packed intf = { 1, 1, 0x3 };
	u32 frame_size_factor = 1;
	u32 power_mode = 0;
	u8 buf[128] __aligned(8);
	u8 *p = buf;
	int rc;

	voice_poc_param(&p, VOICE_POC_SINK_INSTANCE, 0x08001017, &mf, sizeof(mf));
	voice_poc_param(&p, VOICE_POC_SINK_INSTANCE, 0x08001018,
			&frame_size_factor, sizeof(frame_size_factor));
	voice_poc_param(&p, VOICE_POC_SINK_INSTANCE, 0x08001063, &intf,
			sizeof(intf));
	voice_poc_param(&p, VOICE_POC_SINK_INSTANCE, 0x8001176, &power_mode,
			sizeof(power_mode));

	rc = voice_poc_send(apm, APM_CMD_SET_CFG, buf, p - buf);
	dev_info(apm->dev, "voice-poc: sink format -> %d\n", rc);
	return rc;
}
```

Called right after `configure rx`, and only meaningful when the blob carries
stock's device sub-graph:

```c
	/* Only meaningful when the blob carries stock's device sub-graph. */
	voice_poc_configure_sink(apm);
```

The DSP accepted it (`sink format -> 0`) and `GRAPH_START` still failed, so
the format was not the missing piece.

## 3. Per-parameter VCPM logging

The three VCPM parameters and the MFC format used to go out in one `SET_CFG`;
splitting them made each answer visible:

```c
	n = voice_poc_rec(buf, VCPM_MODULE_INSTANCE_ID, 0x080011bc, vsid, sizeof(vsid));
	rc = voice_poc_send(apm, APM_CMD_SET_CFG, buf, n);
	dev_info(apm->dev, "voice-poc: VCPM vsid %#x -> %d\n", vsid[0], rc);
	if (rc)
		return rc;
	/* same shape for 0x08001310 and 0x0800116b */
	dev_info(apm->dev, "voice-poc: MFC format -> %d\n", rc);
```

All four reported `-> 0`, which is what closed the VCPM question.
