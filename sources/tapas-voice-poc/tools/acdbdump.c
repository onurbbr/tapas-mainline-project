// SPDX-License-Identifier: BSD-3-Clause
/*
 * acdbdump: read stock's ACDB with Qualcomm's own AudioReach ACDB library.
 *
 * Stock's audio graph for each device lives in the vendor partition's ACDB
 * (vendor/etc/acdbdata/bengal_idp/IDP_acdb_cal.acdb plus its .qwsp
 * workspace). This links audioreach-graphservices' acdb/ library
 * (BSD-3-Clause, https://github.com/Audioreach/audioreach-graphservices)
 * and asks it, through its public acdb_ioctl() API, what stock sends.
 *
 *   acdbdump FILE.acdb [FILE.qwsp] gkvs          every graph key vector + alias
 *   acdbdump FILE.acdb [FILE.qwsp] graph K=V ... sub-graphs for one GKV
 *   acdbdump ... sgdata SG K=V ...                 a sub-graph's open payload
 *   acdbdump ... tags K=V ...                      tags and their modules
 *   acdbdump ... calkvs K=V ...                    calibration key vectors
 *   acdbdump ... cal SG [CK=CV ...]                a sub-graph's calibration
 *   acdbdump ... tagdata SG TAG [TK=TV ...]        a tag's data
 *   acdbdump ... sgconn SRC_SG DST_SG              connections between two
 * ACDB_RAW=FILE with sgdata or cal also writes the raw blob to FILE.
 *
 * Build (host, against a graphservices checkout G):
 *   cc -O1 -w -I$G/acdb/api -I$G/acdb/inc -I$G/ar_osal/api \
 *      -I$G/ar_util/api -I$G/ar_util/inc -I$G/public_headers \
 *      -D__unused='__attribute__((unused))' \
 *      acdbdump.c <every .c in $G/acdb/src> <ar_osal linux: file_io heap
 *      mem_op mutex string sleep> log_stub.c -o acdbdump -lpthread
 * log_stub.c replaces ar_osal_log.c, which needs Android's liblog. Pass the
 * files as absolute paths: the library derives the directory from them.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "acdb.h"
#include "ar_osal_error.h"

static int add_file(AcdbDataFiles *files, const char *path)
{
	AcdbFile *f = &files->acdbFiles[files->num_files++];

	f->fileNameLen = strlen(path) + 1;
	if (f->fileNameLen > MAX_FILENAME_LENGTH)
		return -1;
	memcpy(f->fileName, path, f->fileNameLen);
	return 0;
}

static void print_alias(AcdbGraphKeyVector *gkv)
{
	char buf[512];
	AcdbString alias = { sizeof(buf), buf };

	buf[0] = '\0';
	if (acdb_ioctl(ACDB_CMD_GET_GRAPH_ALIAS, gkv, sizeof(*gkv), &alias,
		       sizeof(alias)) == AR_EOK)
		printf("  %s", buf);
}

static int dump_gkvs(void)
{
	AcdbUintList keys = { 0 };
	AcdbKeyVectorList list = { 0 };
	uint32_t *p;
	uint32_t i, k;
	int32_t rc;

	rc = acdb_ioctl(ACDB_CMD_GET_SUPPORTED_GKVS, &keys, sizeof(keys),
			&list, sizeof(list));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUPPORTED_GKVS (size): %d\n", rc);
		return 1;
	}
	list.key_vector_list = calloc(1, list.list_size);
	rc = acdb_ioctl(ACDB_CMD_GET_SUPPORTED_GKVS, &keys, sizeof(keys),
			&list, sizeof(list));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUPPORTED_GKVS: %d\n", rc);
		return 1;
	}

	printf("%u graph key vectors\n", list.num_key_vectors);
	p = (uint32_t *)list.key_vector_list;
	for (i = 0; i < list.num_key_vectors; i++) {
		AcdbGraphKeyVector gkv;
		uint32_t n = *p++;

		gkv.num_keys = n;
		gkv.graph_key_vector = (AcdbKeyValuePair *)p;
		printf("GKV %u:", i);
		for (k = 0; k < n; k++)
			printf(" 0x%x=0x%x", p[2 * k], p[2 * k + 1]);
		print_alias(&gkv);
		printf("\n");
		p += 2 * n;
	}
	return 0;
}

static int dump_graph(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	AcdbGraphKeyVector gkv = { 0, kv };
	AcdbGetGraphRsp rsp = { 0 };
	uint8_t *p;
	uint32_t i, j;
	int32_t rc;

	for (i = 0; i < (uint32_t)argc && i < 32; i++) {
		if (sscanf(argv[i], "%i=%i", &kv[i].key, &kv[i].value) != 2) {
			fprintf(stderr, "bad key=value: %s\n", argv[i]);
			return 1;
		}
		gkv.num_keys++;
	}

	rc = acdb_ioctl(ACDB_CMD_GET_GRAPH, &gkv, sizeof(gkv), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_GRAPH (size): %d\n", rc);
		return 1;
	}
	rsp.subgraphs = calloc(1, rsp.size);
	rc = acdb_ioctl(ACDB_CMD_GET_GRAPH, &gkv, sizeof(gkv), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_GRAPH: %d\n", rc);
		return 1;
	}

	print_alias(&gkv);
	printf("\n%u sub-graphs\n", rsp.num_subgraphs);
	p = (uint8_t *)rsp.subgraphs;
	for (i = 0; i < rsp.num_subgraphs; i++) {
		AcdbSubgraph *sg = (AcdbSubgraph *)p;

		printf("  sg 0x%08x ->", sg->sg_id);
		for (j = 0; j < sg->num_dst_sgids; j++)
			printf(" 0x%08x", sg->dst_sg_ids[j]);
		printf("\n");
		p += sizeof(*sg) + sg->num_dst_sgids * sizeof(uint32_t);
	}
	return 0;
}

/*
 * Walk an SPF parameter blob: records of {miid, param_id, size, error}
 * followed by the payload padded to 8 bytes, as APM_CMD_GRAPH_OPEN and
 * APM_CMD_SET_CFG carry them. The module list is decoded; everything else is
 * printed as words.
 */
#define APM_PARAM_ID_MODULE_LIST	0x08001002

/* ACDB_RAW=FILE makes sgdata/cal also write the raw blob, for replaying it. */
static void save_raw(const void *buf, uint32_t len)
{
	const char *path = getenv("ACDB_RAW");
	FILE *f;

	if (!path)
		return;
	f = fopen(path, "wb");
	if (!f || fwrite(buf, 1, len, f) != len)
		perror(path);
	if (f)
		fclose(f);
}

static void dump_params(const uint8_t *p, uint32_t len)
{
	const uint8_t *end = p + len;

	while (p + 16 <= end) {
		const uint32_t *h = (const uint32_t *)p;
		uint32_t miid = h[0], pid = h[1], sz = h[2];
		const uint32_t *w = h + 4;
		uint32_t i;

		printf("  miid 0x%08x param 0x%08x size %u:", miid, pid, sz);
		if (pid == APM_PARAM_ID_MODULE_LIST && sz >= 4) {
			uint32_t nlist = w[0], c, m;
			const uint32_t *q = w + 1;

			printf(" %u container(s)\n", nlist);
			for (c = 0; c < nlist; c++) {
				uint32_t sg = q[0], cont = q[1], n = q[2];

				printf("    sg 0x%08x container 0x%08x:\n", sg, cont);
				q += 3;
				for (m = 0; m < n; m++, q += 2)
					printf("      module 0x%08x instance 0x%08x\n",
					       q[0], q[1]);
			}
		} else {
			for (i = 0; i < sz / 4 && i < 64; i++)
				printf(" %08x", w[i]);
			printf("%s\n", sz / 4 > 64 ? " ..." : "");
		}
		p += 16 + ((sz + 7) & ~7u);
	}
}

static int dump_sgdata(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	uint32_t sg;
	AcdbSgIdGraphKeyVector req = { 1, &sg, { 0, kv } };
	AcdbGetSubgraphDataRsp rsp = { 0 };
	int32_t rc;
	int i;

	if (argc < 1 || sscanf(argv[0], "%i", &sg) != 1)
		return 2;
	for (i = 1; i < argc && i < 33; i++) {
		if (sscanf(argv[i], "%i=%i", &kv[i - 1].key, &kv[i - 1].value) != 2)
			return 2;
		req.graph_key_vector.num_keys++;
	}

	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_DATA, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_DATA (size): %d\n", rc);
		return 1;
	}
	rsp.driver_prop.sub_graph_prop_data = calloc(1, rsp.driver_prop.size + 16);
	rsp.spf_blob.buf = calloc(1, rsp.spf_blob.buf_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_DATA, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_DATA: %d\n", rc);
		return 1;
	}

	printf("sg 0x%08x: driver props %u bytes, spf blob %u bytes\n", sg,
	       rsp.driver_prop.size, rsp.spf_blob.buf_size);
	save_raw(rsp.spf_blob.buf, rsp.spf_blob.buf_size);
	dump_params(rsp.spf_blob.buf, rsp.spf_blob.buf_size);
	return 0;
}

static int parse_kvs(int argc, char **argv, AcdbGraphKeyVector *kv)
{
	int i;

	for (i = 0; i < argc && i < 32; i++) {
		if (sscanf(argv[i], "%i=%i", &kv->graph_key_vector[i].key,
			   &kv->graph_key_vector[i].value) != 2) {
			fprintf(stderr, "bad key=value: %s\n", argv[i]);
			return -1;
		}
		kv->num_keys++;
	}
	return 0;
}

static void print_kv_list(uint32_t count, const uint32_t *p)
{
	uint32_t i, k;

	for (i = 0; i < count; i++) {
		uint32_t n = *p++;

		printf("  KV %u:", i);
		for (k = 0; k < n; k++)
			printf(" 0x%x=0x%x", p[2 * k], p[2 * k + 1]);
		printf("\n");
		p += 2 * n;
	}
}

/* Every calibration key vector a graph's modules are tabled against. */
static int dump_calkvs(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	AcdbGraphKeyVector gkv = { 0, kv };
	AcdbKeyVectorList list = { 0 };
	int32_t rc;

	if (parse_kvs(argc, argv, &gkv))
		return 2;
	rc = acdb_ioctl(ACDB_CMD_GET_GRAPH_CAL_KVS, &gkv, sizeof(gkv), &list,
			sizeof(list));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_GRAPH_CAL_KVS (size): %d\n", rc);
		return 1;
	}
	list.key_vector_list = calloc(1, list.list_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_GRAPH_CAL_KVS, &gkv, sizeof(gkv), &list,
			sizeof(list));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_GRAPH_CAL_KVS: %d\n", rc);
		return 1;
	}
	printf("%u calibration key vectors\n", list.num_key_vectors);
	print_kv_list(list.num_key_vectors, (uint32_t *)list.key_vector_list);
	return 0;
}

/* Tags (the hooks the driver sets at runtime) and the modules under them. */
static int dump_tags(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	AcdbGraphKeyVector gkv = { 0, kv };
	AcdbCmdGetTagsFromGkvReq req = { &gkv };
	AcdbCmdGetTagsFromGkvRsp rsp = { 0 };
	uint32_t *p, i, m;
	int32_t rc;

	if (parse_kvs(argc, argv, &gkv))
		return 2;
	rc = acdb_ioctl(ACDB_CMD_GET_TAGS_FROM_GKV, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_TAGS_FROM_GKV (size): %d\n", rc);
		return 1;
	}
	rsp.tag_module_list = calloc(1, rsp.list_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_TAGS_FROM_GKV, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_TAGS_FROM_GKV: %d\n", rc);
		return 1;
	}
	p = (uint32_t *)rsp.tag_module_list;
	for (i = 0; i < rsp.num_tags; i++) {
		uint32_t tag = *p++, n = *p++;

		printf("tag 0x%08x:", tag);
		for (m = 0; m < n; m++, p += 2)
			printf(" 0x%08x/0x%x", p[0], p[1]);
		printf("\n");
	}
	return 0;
}

/* Non-persistent calibration for one sub-graph under one CKV. */
static int dump_cal(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	uint32_t sg;
	AcdbSgIdCalKeyVector req = { 1, &sg, { 0, NULL }, { 0, kv } };
	AcdbBlob rsp = { 0 };
	int32_t rc;

	if (argc < 1 || sscanf(argv[0], "%i", &sg) != 1)
		return 2;
	if (parse_kvs(argc - 1, argv + 1, &req.cal_key_vector_new))
		return 2;
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CALIBRATION_DATA_NONPERSIST, &req,
			sizeof(req), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CALIBRATION_DATA_NONPERSIST (size): %d\n",
			rc);
		return 1;
	}
	rsp.buf = calloc(1, rsp.buf_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CALIBRATION_DATA_NONPERSIST, &req,
			sizeof(req), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CALIBRATION_DATA_NONPERSIST: %d\n", rc);
		return 1;
	}
	printf("sg 0x%08x: calibration %u bytes\n", sg, rsp.buf_size);
	save_raw(rsp.buf, rsp.buf_size);
	dump_params(rsp.buf, rsp.buf_size);
	return 0;
}

/*
 * Persistent calibration for one sub-graph under one CKV: what stock's AGM
 * sends with APM_CMD_REGISTER_CFG (voice graphs register several blocks).
 * The response is a list of {sg_id, size, records}; the records are saved raw.
 */
static int dump_pcal(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	uint32_t sg;
	AcdbSgIdCalKeyVector req = { 1, &sg, { 0, NULL }, { 0, kv } };
	AcdbSgIdPersistCalData rsp = { 0 };
	AcdbSgIdPersistData *d;
	uint32_t off = 0;
	int32_t rc;

	if (argc < 1 || sscanf(argv[0], "%i", &sg) != 1)
		return 2;
	if (parse_kvs(argc - 1, argv + 1, &req.cal_key_vector_new))
		return 2;
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CALIBRATION_DATA_PERSIST, &req,
			sizeof(req), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CALIBRATION_DATA_PERSIST (size): %d\n", rc);
		return 1;
	}
	rsp.cal_data = calloc(1, rsp.cal_data_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CALIBRATION_DATA_PERSIST, &req,
			sizeof(req), &rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CALIBRATION_DATA_PERSIST: %d\n", rc);
		return 1;
	}
	printf("sg 0x%08x: persistent calibration, %u sub-graph(s), %u bytes\n",
	       sg, rsp.num_sg_ids, rsp.cal_data_size);
	while (off + sizeof(*d) <= rsp.cal_data_size) {
		d = (AcdbSgIdPersistData *)((uint8_t *)rsp.cal_data + off);
		printf("  sg 0x%08x: %u bytes\n", d->sg_id, d->persist_data_size);
		if (d->sg_id == sg)
			save_raw(d->buf, d->persist_data_size);
		dump_params((uint8_t *)d->buf, d->persist_data_size);
		off += sizeof(*d) + d->persist_data_size;
	}
	return 0;
}

/* Print a blob as words, then any printable runs (library names) in it. */
static void dump_words_strings(const uint8_t *b, uint32_t len)
{
	uint32_t i, run = 0;

	for (i = 0; i + 4 <= len; i += 4)
		printf("%s%08x", i % 32 ? " " : "\n  ", *(const uint32_t *)(b + i));
	printf("\n  strings:");
	for (i = 0; i <= len; i++) {
		if (i < len && b[i] >= 0x20 && b[i] < 0x7f) {
			run++;
			continue;
		}
		if (run >= 4)
			printf(" \"%.*s\"", run, (const char *)b + i - run);
		run = 0;
	}
	printf("\n");
}

/* Dynamic modules the HLOS registers with the DSP's AMDB, and boot-time loads. */
static int dump_amdb(int argc, char **argv)
{
	AcdbAmdbProcID proc = { 2 };	/* APM_PROC_DOMAIN_ID_ADSP */
	uint32_t cmds[2] = { ACDB_CMD_GET_AMDB_REGISTRATION_DATA,
			     ACDB_CMD_GET_AMDB_BOOTUP_LOAD_MODULES };
	const char *names[2] = { "registration", "bootup load" };
	int i;

	if (argc > 0)
		sscanf(argv[0], "%i", &proc.proc_id);
	for (i = 0; i < 2; i++) {
		AcdbBlob rsp = { 0 };
		int32_t rc;

		rc = acdb_ioctl(cmds[i], &proc, sizeof(proc), &rsp, sizeof(rsp));
		if (rc != AR_EOK) {
			printf("%s: %d\n", names[i], rc);
			continue;
		}
		rsp.buf = calloc(1, rsp.buf_size + 16);
		rc = acdb_ioctl(cmds[i], &proc, sizeof(proc), &rsp, sizeof(rsp));
		printf("%s (proc %u): rc %d, %u bytes", names[i], proc.proc_id, rc,
		       rsp.buf_size);
		if (rc == AR_EOK)
			dump_words_strings(rsp.buf, rsp.buf_size);
		else
			printf("\n");
	}
	return 0;
}

/* The connections from one sub-graph into another (they live in neither). */
static int dump_sgconn(int argc, char **argv)
{
	struct {
		uint32_t sg_id;
		uint32_t num_dst_sgids;
		uint32_t dst;
	} sg;
	AcdbSubGraphList req = { 1, (AcdbSubgraph *)&sg };
	AcdbBlob rsp = { 0 };
	int32_t rc;

	if (argc < 2 || sscanf(argv[0], "%i", &sg.sg_id) != 1 ||
	    sscanf(argv[1], "%i", &sg.dst) != 1)
		return 2;
	sg.num_dst_sgids = 1;
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CONNECTIONS, &req, sizeof(req),
			&rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CONNECTIONS (size): %d\n", rc);
		return 1;
	}
	rsp.buf = calloc(1, rsp.buf_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_SUBGRAPH_CONNECTIONS, &req, sizeof(req),
			&rsp, sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_SUBGRAPH_CONNECTIONS: %d\n", rc);
		return 1;
	}
	printf("0x%08x -> 0x%08x: %u bytes\n", sg.sg_id, sg.dst, rsp.buf_size);
	save_raw(rsp.buf, rsp.buf_size);
	dump_params(rsp.buf, rsp.buf_size);
	return 0;
}

/* What a tagged module gets under one tag key vector, e.g. the I2S config. */
static int dump_tagdata(int argc, char **argv)
{
	AcdbKeyValuePair kv[32];
	uint32_t sg;
	AcdbSgIdModuleTag req = { 1, &sg, { 0, { 0, kv } } };
	AcdbBlob rsp = { 0 };
	int32_t rc;

	if (argc < 2 || sscanf(argv[0], "%i", &sg) != 1 ||
	    sscanf(argv[1], "%i", &req.module_tag.tag_id) != 1)
		return 2;
	if (parse_kvs(argc - 2, argv + 2, &req.module_tag.tag_key_vector))
		return 2;
	rc = acdb_ioctl(ACDB_CMD_GET_MODULE_TAG_DATA, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_MODULE_TAG_DATA (size): %d\n", rc);
		return 1;
	}
	rsp.buf = calloc(1, rsp.buf_size + 16);
	rc = acdb_ioctl(ACDB_CMD_GET_MODULE_TAG_DATA, &req, sizeof(req), &rsp,
			sizeof(rsp));
	if (rc != AR_EOK) {
		fprintf(stderr, "GET_MODULE_TAG_DATA: %d\n", rc);
		return 1;
	}
	printf("sg 0x%08x tag 0x%08x: %u bytes\n", sg, req.module_tag.tag_id,
	       rsp.buf_size);
	dump_params(rsp.buf, rsp.buf_size);
	return 0;
}

int main(int argc, char **argv)
{
	AcdbDataFiles files = { 0 };
	int a = 1;
	int32_t rc;

	if (argc < 3) {
		fprintf(stderr, "usage: %s FILE.acdb [FILE.qwsp] gkvs|graph K=V...\n",
			argv[0]);
		return 2;
	}
	add_file(&files, argv[a++]);
	if (strstr(argv[a], ".qwsp"))
		add_file(&files, argv[a++]);

	rc = acdb_init(&files, NULL);
	if (rc != AR_EOK) {
		fprintf(stderr, "acdb_init: %d\n", rc);
		return 1;
	}

	if (!strcmp(argv[a], "gkvs"))
		return dump_gkvs();
	if (!strcmp(argv[a], "graph"))
		return dump_graph(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "sgdata"))
		return dump_sgdata(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "calkvs"))
		return dump_calkvs(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "tags"))
		return dump_tags(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "pcal"))
		return dump_pcal(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "cal"))
		return dump_cal(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "tagdata"))
		return dump_tagdata(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "sgconn"))
		return dump_sgconn(argc - a - 1, argv + a + 1);
	if (!strcmp(argv[a], "amdb"))
		return dump_amdb(argc - a - 1, argv + a + 1);

	fprintf(stderr, "unknown command %s\n", argv[a]);
	return 2;
}
