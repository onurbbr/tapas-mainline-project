#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Build fogona's voice-call graph files from the phone's own stock ACDB.

    fogona-voice-graphs.py --acdbdump PATH --acdb FILE.acdb --qwsp FILE.qwsp \\
        --out DIR

Calls `acdbdump` (tools/acdb/acdbdump.c) on stock's ACDB for each sub-graph,
sub-graph connection and persistent calibration table it needs, and writes:

  voice-rx5-open.bin  APM_CMD_GRAPH_OPEN for voice RX: stock's voice RX
                      sub-graphs b0000044, b0000041 and b0000040, without
                      b0000045 (on a call its container never got a frame
                      length and the downlink stopped there). Stock's edges
                      into its earpiece device sub-graph b000002a are pointed
                      at the topology's backend instead: device SAL 0x40e1 ->
                      topology SAL 0x6004, 0x43b3 -> 0x6003. The RX output
                      0x41dc (which fed b0000045) is bridged into the backend
                      SAL 0x6004, input port 8.
  voice-rx5-cfg.bin   APM_CMD_SET_CFG for voice RX: the non-graph records the
                      sub-graphs carry (VCPM_PARAM_ID_VOICE_CONFIG to VCPM
                      0x4), then PCM logging enabled on 0x41dc and 0x41b8.
  voice-tx-open.bin   GRAPH_OPEN for voice TX: stock's voice TX sub-graphs
                      b00000b1 and b000003f without its mic device sub-graph
                      b0000039. Mics come from the topology's capture
                      splitter 0x6091 (stock 0x4167; 0x43af -> 0x6090), the
                      echo reference from splitter 0x6005 output port 3 into
                      Fluence ECNS 0x4448 port 4.
  voice-tx-cfg.bin    SET_CFG for voice TX: the non-graph records, stock's
                      persistent (VCPM cal table) calibration for b00000b1 at
                      16 kHz plus its key-less defaults and for b000003f at
                      16 kHz, PCM logging on six TX modules, then the AMR-WB
                      (AMR class, 16 kHz) records of 0x455f
                      (0x800115a = 20). Records over 3568 bytes of payload
                      are left out: they do not fit one SET_CFG.

These are byte-identical to the files built by hand in
investigations/call-audio.md ("Rebuilding stock's voice graphs on mainline",
"Two-way call audio"): voice-rx5-*, voice-tx12-open and voice-tx8-cfg in
out/stock-acdb/voice/.

The merge logic of tools/acdb/merge-graph.py is inlined below so that this
file runs alone (on the phone at boot).
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------- ACDB keys
# Graph key vectors of stock's voice call (AGM log; call-audio.md).
RX_GKV = ["0xa1000000=0xa1000010", "0xb3000000=0xb3000001",
          "0xaf000000=0xaf000001", "0xa2000000=0xa2000004",
          "0xac000000=0xac000005"]
TX_GKV = ["0xb1000000=0xb1000007", "0xb3000000=0xb3000001",
          "0xa3000000=0xa3000004", "0xad000000=0xad000009"]

# Sub-graphs whose connections are queried (every ordered pair; pairs with
# no connection are skipped). RX includes the earpiece device b000002a and
# b0000045, whose edges the --map/--bridge below re-point.
RX_CONN_SGS = [0xb000002a, 0xb0000045, 0xb0000044, 0xb0000041, 0xb0000040]
TX_CONN_SGS = [0xb0000039, 0xb00000b1, 0xb000003f]

RX_SGS = [0xb0000044, 0xb0000041, 0xb0000040]
TX_SGS = [0xb00000b1, 0xb000003f]

RX_MAP = {0x40e1: 0x6004, 0x43b3: 0x6003}
RX_BRIDGE = [(0x41dc, 1, 0x6004, 8)]
TX_MAP = {0x4167: 0x6091, 0x43af: 0x6090, 0x41d4: 0x41d4, 0x41d5: 0x41d5}
TX_BRIDGE = [(0x6005, 3, 0x4448, 4)]

# PCM logging (0x08001026 enable, 0x08001031 {tap 0x1586, miid, 0}).
RX_LOG_MODULES = [0x41dc, 0x41b8]
TX_LOG_MODULES = [0x444b, 0x4450, 0x48a6, 0x4456, 0x47b8, 0x41ad]
PARAM_LOG_ENABLE = 0x08001026
PARAM_LOG_CFG = 0x08001031
LOG_TAP = 0x1586

# VCPM calibration keys (spf/api/vcpm/vcpm_api.h).
VCPM_PARAM_ID_CAL_TABLE = 0x08001163
KEY_VOCODER_CLASS = 0x08001164
KEY_SAMPLING_RATE = 0x08001165
VOCODER_CLASS_AMR = 0x08001168

MAX_CFG_PARAM = 3584  # header + payload of one record in one SET_CFG


# ------------------------------------------------------- record primitives
def records(blob):
    """(miid, pid, payload) of each <miid, pid, size, err> record."""
    off = 0
    while off + 16 <= len(blob):
        miid, pid, size, _ = struct.unpack_from("<4I", blob, off)
        yield miid, pid, blob[off + 16:off + 16 + size]
        off += 16 + ((size + 7) & ~7)


def pack(miid, pid, payload):
    rec = struct.pack("<4I", miid, pid, len(payload), 0) + payload
    return rec + b"\0" * ((-len(rec)) % 8)


def words(b):
    return list(struct.unpack("<%dI" % (len(b) // 4), b))


# ------------------------------------------ merge-graph.py (inlined logic)
SG_CONFIG = 0x08001001
CONT_CONFIG = 0x08001000
MOD_LIST = 0x08001002
MOD_PROP = 0x08001003
MOD_CONN = 0x08001004
CTRL_LINK = 0x08001061
ORDER = [SG_CONFIG, CONT_CONFIG, MOD_LIST, MOD_PROP, MOD_CONN, CTRL_LINK]


def props_end(w, j, n):
    for _ in range(n):
        j += 2 + (w[j + 1] + 3) // 4
    return j


def split_entries(pid, w):
    out, i = [], 1
    for _ in range(w[0]):
        if pid in (SG_CONFIG, CONT_CONFIG, MOD_PROP):
            j = props_end(w, i + 2, w[i + 1])
            out.append((w[i], w[i:j]))
        elif pid == MOD_LIST:
            j = i + 3 + 2 * w[i + 2]
            out.append(((w[i], w[i + 1]), w[i:j]))
        elif pid == MOD_CONN:
            j = i + 4
            out.append((tuple(w[i:j]), w[i:j]))
        elif pid == CTRL_LINK:
            j = props_end(w, i + 5, w[i + 4])
            out.append((tuple(w[i:i + 4]), w[i:j]))
        else:
            raise ValueError("unknown param %#x" % pid)
        i = j
    return out


def merge_graph(blobs, bridges, remap):
    """One GRAPH_OPEN from sub-graph and connection blobs, as merge-graph.py.

    Returns (open payload, non-graph records, module instances)."""
    entries = {pid: {} for pid in ORDER}
    extra = []
    for blob in blobs:
        for miid, pid, pl in records(blob):
            if pid not in entries:
                extra.append(pack(miid, pid, pl))
                continue
            for key, e in split_entries(pid, words(pl)):
                entries[pid].setdefault(key, e)

    mods = set()
    for e in entries[MOD_LIST].values():
        mods.update(e[4 + 2 * k] for k in range(e[2]))
    ends = mods | set(remap.values())
    for c in bridges:
        entries[MOD_CONN][tuple(c)] = list(c)
        ends |= {c[0], c[2]}
    for pid in (MOD_CONN, CTRL_LINK):
        kept = {}
        for e in entries[pid].values():
            e = list(e)
            e[0] = remap.get(e[0], e[0])
            e[2] = remap.get(e[2], e[2])
            if e[0] in ends and e[2] in ends and (e[0] in mods or e[2] in mods):
                kept[tuple(e[:4])] = e
        entries[pid] = kept

    out = b""
    for pid in ORDER:
        es = list(entries[pid].values())
        if not es:
            continue
        w = [len(es)] + [x for e in es for x in e]
        out += pack(1, pid, struct.pack("<%dI" % len(w), *w))
    return out, b"".join(extra), mods


# ------------------------------------------------- VCPM cal table parsing
def vcpm_cal_objects(blob, sg):
    """Parse a VCPM_PARAM_ID_CAL_TABLE blob (`acdbdump pcal SG`).

    Layout (acdb_command.c, BuildVcpmBlob): the record header, then the
    sub-graph info chunk {num_sgs, sg, table_size, major, minor, master key
    offset, num CKV tables, tables}, each table {size, key id table offset,
    cal dot size, num objects, objects}, each object {CKV LUT offset, n,
    n x <data pool offset, persistent>}; then four chunks each prefixed by
    its size: master keys, key id tables, key value LUTs, data pool. Data
    pool entries are ordinary <miid, pid, size, err> records.

    Returns [(ckv dict, [(byte offset, miid, pid, size)...])...]."""
    w = words(blob)
    if len(w) < 11 or w[1] != VCPM_PARAM_ID_CAL_TABLE or w[4] != 1 or w[5] != sg:
        raise ValueError("sg %#x: not a one-sub-graph VCPM cal table" % sg)
    table_size = w[6]
    i, ntab = 11, w[10]
    tables = []
    for _ in range(ntab):
        _, key_off, _, nobj = w[i:i + 4]
        i += 4
        objs = []
        for _ in range(nobj):
            lut_off, n = w[i:i + 2]
            objs.append((lut_off, [w[i + 2 + 2 * k] for k in range(n)]))
            i += 2 + 2 * n
        tables.append((key_off, objs))
    if i != 4 + (12 + table_size) // 4:
        raise ValueError("sg %#x: sub-graph info chunk size mismatch" % sg)
    chunks = []
    for _ in range(4):
        size = w[i]
        chunks.append(i + 1)
        i += 1 + size // 4
    _, key_base, lut_base, pool_base = chunks
    if i * 4 != 16 + w[2]:  # record payload size; the record is 8-padded
        raise ValueError("sg %#x: VCPM cal table size mismatch" % sg)

    out = []
    for key_off, objs in tables:
        k = key_base + key_off // 4
        keys = w[k + 1:k + 1 + w[k]]
        for lut_off, pool_offs in objs:
            v = lut_base + lut_off // 4
            vals = w[v + 1:v + 1 + w[v]]
            if len(vals) != len(keys):
                raise ValueError("sg %#x: CKV key/value count mismatch" % sg)
            recs = []
            for po in pool_offs:
                pos = (pool_base * 4) + po
                miid, pid, size, _ = struct.unpack_from("<4I", blob, pos)
                recs.append((pos, miid, pid, size))
            out.append((dict(zip(keys, vals)), recs))
    return out


def select_cal(blob, cal_objects, want, modules):
    """Records of every cal object whose CKV is one of `want`, limited to
    `modules`, in blob order."""
    picked = set()
    for ckv, recs in cal_objects:
        if ckv in want:
            picked.update(r for r in recs if r[1] in modules)
    return b"".join(blob[pos:pos + 16 + ((size + 7) & ~7)]
                    for pos, _, _, size in sorted(picked))


def log_records(mods):
    return b"".join(pack(m, PARAM_LOG_ENABLE, struct.pack("<I", 1)) +
                    pack(m, PARAM_LOG_CFG, struct.pack("<3I", LOG_TAP, m, 0))
                    for m in mods)


# ------------------------------------------------------------- acdbdump I/O
class Acdb:
    def __init__(self, tool, acdb, qwsp, tmp):
        self.base = [tool, os.path.abspath(acdb), os.path.abspath(qwsp)]
        self.tmp = tmp
        self.n = 0
        self.log = []

    def raw(self, *args, missing_ok=None):
        """Run acdbdump with ACDB_RAW and return the raw blob.

        missing_ok: an stderr prefix meaning "no such data" (returns None)."""
        self.n += 1
        path = os.path.join(self.tmp, "raw%03d.bin" % self.n)
        env = dict(os.environ, ACDB_RAW=path)
        cmd = self.base + [str(a) for a in args]
        self.log.append(" ".join(str(a) for a in args))
        p = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=120)
        err = p.stderr.decode(errors="replace")
        if p.returncode == 1 and missing_ok and not os.path.exists(path) and \
                any(l.startswith(missing_ok) for l in err.splitlines()):
            return None
        if p.returncode != 0 or not os.path.exists(path):
            raise RuntimeError("acdbdump %s: exit %d\n%s" % (
                " ".join(str(a) for a in args), p.returncode,
                "\n".join(err.splitlines()[-5:])))
        with open(path, "rb") as f:
            return f.read()

    def sgdata(self, sg, gkv):
        return self.raw("sgdata", "%#x" % sg, *gkv)

    def pcal(self, sg):
        return self.raw("pcal", "%#x" % sg)

    def conns(self, sgs):
        """Connection blobs of every connected ordered pair, in (src, dst)
        order."""
        out = []
        for src in sorted(sgs):
            for dst in sorted(sgs):
                if src != dst:
                    b = self.raw("sgconn", "%#x" % src, "%#x" % dst,
                                 missing_ok="GET_SUBGRAPH_CONNECTIONS")
                    if b is not None:
                        out.append(b)
        return out


# --------------------------------------------------------------------- build
def build(acdb):
    files = {}

    # Voice RX.
    rx_open, rx_extra, _ = merge_graph(
        [acdb.sgdata(sg, RX_GKV) for sg in RX_SGS] + acdb.conns(RX_CONN_SGS),
        RX_BRIDGE, RX_MAP)
    files["voice-rx5-open.bin"] = rx_open
    files["voice-rx5-cfg.bin"] = rx_extra + log_records(RX_LOG_MODULES)

    # Voice TX.
    tx_open, tx_extra, tx_mods = merge_graph(
        [acdb.sgdata(sg, TX_GKV) for sg in TX_SGS] + acdb.conns(TX_CONN_SGS),
        TX_BRIDGE, TX_MAP)
    files["voice-tx-open.bin"] = tx_open

    b1 = acdb.pcal(0xb00000b1)
    b3f = acdb.pcal(0xb000003f)
    b1_objs = vcpm_cal_objects(b1, 0xb00000b1)
    b3f_objs = vcpm_cal_objects(b3f, 0xb000003f)
    wb = {KEY_SAMPLING_RATE: 16000}
    amr_wb = {KEY_VOCODER_CLASS: VOCODER_CLASS_AMR, KEY_SAMPLING_RATE: 16000}
    cfg = (tx_extra +
           select_cal(b1, b1_objs, [wb, {}], tx_mods) +
           select_cal(b3f, b3f_objs, [wb], tx_mods) +
           log_records(TX_LOG_MODULES))
    cfg = b"".join(pack(m, p, pl) for m, p, pl in records(cfg)
                   if 16 + len(pl) <= MAX_CFG_PARAM)
    vocoder = select_cal(b3f, b3f_objs, [amr_wb], {0x455f})
    if not vocoder:
        raise RuntimeError("no AMR-WB calibration for 0x455f")
    files["voice-tx-cfg.bin"] = cfg + vocoder
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--acdbdump", required=True)
    ap.add_argument("--acdb", required=True)
    ap.add_argument("--qwsp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the acdbdump invocations")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="fogona-voice-graphs.")
    written = []
    try:
        acdb = Acdb(a.acdbdump, a.acdb, a.qwsp, tmp)
        files = build(acdb)
        if a.verbose:
            for l in acdb.log:
                print("acdbdump", l)
        os.makedirs(a.out, exist_ok=True)
        # Runs on every boot: leave files that already match alone, so an
        # unchanged ACDB writes nothing.
        def same(name, data):
            try:
                with open(os.path.join(a.out, name), "rb") as f:
                    return f.read() == data
            except OSError:
                return False
        for name, data in files.items():
            if same(name, data):
                continue
            t = os.path.join(a.out, ".%s.tmp" % name)
            with open(t, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            written.append((t, os.path.join(a.out, name)))
        for t, final in written:
            os.replace(t, final)
        written = []
    except Exception as e:
        print("fogona-voice-graphs: %s" % e, file=sys.stderr)
        return 1
    finally:
        for t, _ in written:
            try:
                os.unlink(t)
            except OSError:
                pass
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
