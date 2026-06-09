# Vector (RVV) commit logging — `instr_tracer_synth`

This adds **vector instruction** lines to the synthesizable tracer's commit log,
in Spike `--log-commits` format. It is the *synthesizable, byte-exact* option:
the destination vector register is captured on-chip from a shadow copy of Ara's
VRF and streamed off-chip, then formatted to ASCII (in the sim sink, or off-chip
decoder) — the same on-chip-capture / off-chip-format split the scalar path uses.

> ⚠️ **Status: implemented but NOT yet simulated.** No Verilator/QuestaSim build
> was available when this was written. The format/de-shuffle logic and the VRF
> addressing are derived from the Ara source (references below), but the
> hierarchical taps, the `AddrInBank` assumption, and the timing/ordering need a
> simulation pass to confirm. See **§6 Validation**.

---

## 1. The Spike vector format we reproduce

Per [`trace_vector.md`](trace_vector.md) (§1, §2.1, §3.2) — the spec for the
targeted Spike commit-log version — when an instruction writes a vector register
the line is the standard header followed by one ` v<vd> 0x…` per written register:

```
<priv> 0x<pc> (0x<insn>) v<vd> 0x<VLEN-bit hex>
```

- `v<vd> 0x…`— the full `VLEN`-bit register (no `vl`/`vstart`/`vta`/`vma` masking),
  high element to the **left** (MSB), element 0 to the **right** (LSB); bytes are
  in the register's *architectural* (natural) order.

> **Version note.** The `v<n>` print format differs between Spike builds (older
> per-element `v8 : [3]: 0x.. [2]: 0x..` vs. the newer single hex string; and some
> builds additionally prefix an `e<sew> <m|mf><lmul> l<vl>` vtype summary). This
> tracer targets the bare-hex-string form **without** the vtype summary, matching
> `trace_vector.md`. If your Spike emits the summary, re-add it in
> `instr_tracer_synth_sink.sv::spike_vec_str` (the `vsew/vlmul/vl` fields are still
> captured) or diff with `compare_spike_log.py --no-vec`.

Mem (`mem 0x…`) and CSR (`c<addr>_…`) tokens reuse the scalar path.

## 2. Where the data lives, and the byte order

Ara stripes each vector register across `NrLanes` lanes and, within a lane, across
`NrVRFBanksPerLane = 8` banks of 64-bit words (RVV v0.9 striping, SLEN = 64). The
mapping (from `ara_pkg.sv` / `operand_requester.sv`):

- `vaddr_t` is a **global 64-bit-word index** in a lane's VRF.
- bank holding global word `gw` is `gw[$clog2(NrBanks)-1:0]`; the per-bank ("in-bank")
  word address driven on `vrf_addr` is `gw >> $clog2(NrBanks)`
  (reads: `operand_requester.sv:353/358`; result writes: `:457-502`).
- register `vid` starts at global word `vaddr(vid) = vid * (VLENB/NrLanes/8)`
  (`ara_pkg.sv:980`).

So a write tapped at lane `L`, bank `b`, in-bank address `a` maps to global word
`gw = (a << 3) | b`. Reading `v[vid]` concatenates words `vid*Wpr .. +Wpr-1` from
each lane, in the physical (lane-shuffled) layout. The formatter de-shuffles to
architectural order with **Ara's own** `ara_pkg::shuffle_index(n, NrLanes, ew)`
(`ara_pkg.sv:449`), so the byte order is correct by construction.

## 3. Files

| File | Role | Synthesizable? |
|---|---|---|
| `instr_tracer_synth_pkg.sv` | adds `vec_commit_log_pkt_t` (valid/first/last, priv, pc, instr, vsew, vlmul, vl, vd, raw `data[VLEN]`) | ✅ |
| `instr_tracer_synth_vrf_shadow.sv` | **shadow VRF**: mirrors every lane bank write (`gw=(addr<<3)\|bank`), reads back `v[vid]` as raw lane-shuffled `VLEN` bits | ✅ |
| `instr_tracer_synth_vec.sv` | detects an `ACCEL` commit that writes a vreg, decodes `vd`, snapshots the shadow VRF, reads Ara `vsew/vlmul/vl`, packs + FIFOs the record | ✅ |
| `instr_tracer_synth_sink.sv` | de-shuffles + prints the Spike vector line; **suppresses** the scalar line for vector-handled instrs and emits the vector line **in program order** | ❌ (sim) |
| `tb/tb_ara_system_trace.sv` | system-level wiring (taps `i_ariane.*` + `i_ara.*`) | ❌ (sim) |

## 4. How it integrates (system level)

A vector instruction's scalar half retires in CVA6 (`fu == ACCEL`), but its data is
in Ara — so this is wired at the **`ara_system`** level (in `tb_ara_system_trace.sv`),
not in the `ariane`-scoped `bind` (which can't see Ara). Taps:

- commit: `i_ara`… no — `i_dut.i_ariane.commit_instr_id_commit / commit_ack / priv_lvl / debug_mode`
- vtype/vl: `i_dut.i_ara.i_dispatcher.vtype_q.{vsew,vlmul}` , `…​.vl_q`
- VRF writes: `i_dut.i_ara.gen_lanes[L].i_lane.{vrf_wen,vrf_addr,vrf_wdata,vrf_be}`

**Program order:** the vector FIFO is popped *exactly* when the scalar stream drains
a vector-handled instruction (`vec_pop` in the sink), so the vector line lands at the
same position the suppressed scalar line would have. Both streams are in commit
order, so the k-th vector-handled scalar beat aligns with the k-th vector record.

## 5. Coverage (v1) and known limitations

**Handled byte-exactly (intended):** single-register destinations at `EEW = vtype.vsew`
— OP-V arithmetic / mask ops (opcode `0x57`, funct3 ≠ OPCFG) and unit-stride vector
loads (opcode `0x07`), `LMUL ≤ 1`.

**Handled — was a TODO, now done:**
- **Reductions/moves to a SCALAR** (`vmv.x.s`, `vcpop.m`, `vfirst.m`, `vfmv.f.s`) —
  opcode `0x57`, funct3 ≠ OPCFG but `VWXUNARY0/VWFUNARY0` (funct6 `010000`, funct3
  `OPMVV`/`OPFVV`) write `x`/`f`, not `vd`. `writes_vreg()`/`vec_handled()` now
  exclude them, so they emit the correct `x<rd>`/`f<rd>` scalar line (`trace_vector.md`
  §3.10). `vmv.s.x`/`vfmv.s.f` (same funct6, `OPMVX`/`OPFVF`) still write a vreg and
  stay on the vector path.
- **Mask-result EEW** (`trace_vector.md` §3.13) — compares (`vmseq`/`vmslt`/…/`vmfeq`…),
  mask-logicals, `vmadc`/`vmsbc`, and `vmsbf`/`vmsif`/`vmsof` write a bit-packed mask.
  The sink (`is_mask_result`) now de-shuffles those at **EW8** instead of `vsew`, so
  bit *i* = element *i*. ⚠️ Assumes Ara stores a mask with EW8 striping — **confirm in sim**.
- **Vector-FP fflags** (`trace_vector.md` §3.14) — the vector tracer taps the per-lane
  `fflags_ex_i`/`fflags_ex_valid_i` bus into the dispatcher, OR-reduces it, and the sink
  appends `c1_fflags 0x<val>` to an OPFVV/OPFVF line. ⚠️ Best-effort timing (flags
  captured at the FP-op commit, like all vector data) — **confirm in sim**.

**Not yet handled — documented TODOs:**
1. **LMUL > 1 (EMUL > 1)** — Spike prints `v<vd>, v<vd+1>, …` on one line. The record
   has `first`/`last` flags for this, but the capture currently emits one register
   (`first=last=1`). Needs a small per-instruction loop pushing `emul` records.
2. **Widening dest (2·SEW)** — the de-shuffle uses `vtype.vsew`; a widening write
   produces 2·SEW elements, so those bytes will be mis-ordered. (Mask EEW is now
   handled — see above.)
3. **Vector stores** (opcode `0x27`) — not emitted by the vector path; the scalar
   path prints a bare line (no `mem` tokens). `trace_vector.md` §3.5 wants one
   `mem 0x<addr> 0x<value>` per element. **Selected for implementation** — the viable
   route is reconstruction from the shadow VRF (`v[vs3]`, and `v[vs2]` for indexed) +
   base/stride scalar-operand taps, since per-element data is **not** observable at the
   AXI level for unit-stride. Sizeable, timing-sensitive; pending.
4. **vset\* vtype/vl tokens** — writes `x<rd>` (scalar path) + `c3105_vtype`/`c3104_vl`.
   **Selected for implementation** — requires a scalar↔vector merge in the sink (emit a
   vtype/vl side-record on a vset commit, append its tokens to the scalar `x<rd>` line);
   pending. `c3104`=vl, `c3105`=vtype (RVV CSR 0xC20/0xC21).
5. **In-flight vtype/vl** — we read Ara's *current* `vtype_q/vl_q` (like the scalar
   shadow regfile reads "most recent"); if a later vset has updated them before this
   instr commits, the de-shuffle EEW (`vsew`) can differ. Per-instruction
   `pe_req.vtype/vl` (correlated by id) would be exact.
6. **Two vector instrs retiring in one cycle** — the capture takes the first port only.
7. **Tail/`vta`** — Spike prints the whole `VLEN`; tail bytes match only if Ara's tail
   policy matches Spike's.
8. **`AddrInBank`** — assumes per-bank `vrf_addr` is the in-bank word index (current
   Ara). Flip the parameter if a future revision drives the global word.

## 6. Validation (do this first in simulation)

```bash
# Build an app that uses vectors, run the trace sim (QuestaSim flow):
make -C apps bin/imatmul                       # or fmatmul / dotproduct
make -C hardware app=imatmul simc              # needs tb_ara_system_trace wired in
# Golden: Spike with vector commit logging
spike --isa=rv64gcv --log-commits imatmul.elf 2> spike.log
# Compare (vector lines included). Bring-up aids:
python3 scripts/compare_spike_log.py spike.log hardware/build/trace_hart_0_commit.synth.log
python3 scripts/compare_spike_log.py spike.log … --no-vreg   # ignore v-data while validating
```

Suggested bring-up order: (a) confirm the `e<sew> <lmul> l<vl> v<vd>` *metadata*
matches (use `--no-vreg`); (b) confirm a single `e32/e64`, `LMUL=1` `vadd`'s data
matches byte-for-byte; if not, first suspect `AddrInBank` then the lane/physical
byte mapping in `instr_tracer_synth_vrf_shadow.sv` read loop; (c) extend to the
TODOs above.

---

*Companion to [README.md](README.md), [ARCHITECTURE.md](ARCHITECTURE.md), [TUTORIAL.md](TUTORIAL.md).*
