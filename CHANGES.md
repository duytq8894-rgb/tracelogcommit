# Update summary

New **vector (RVV) commit logging** feature for the synthesizable CVA6+Ara tracer,
plus architecture documentation. Logs Ara vector instructions in Spike
`--log-commits` format:

```
<priv> 0x<pc> (0x<insn>) e<sew> <m|mf><lmul> l<vl> v<vd> 0x<VLEN-bit hex>
```

## New files
| File | Purpose | Synth? | Status |
|---|---|---|---|
| `hardware/src/trace/instr_tracer_synth_vrf_shadow.sv` | shadow copy of Ara's VRF; mirrors lane bank writes, reads back `v[vid]` | ✅ | ⚠️ unsimulated |
| `hardware/src/trace/instr_tracer_synth_vec.sv` | vector capture: ACCEL-commit detect → decode `vd` → snapshot → pack record | ✅ | ⚠️ unsimulated |
| `hardware/src/trace/VECTOR.md` | vector design, VRF byte-order/addressing, coverage, **validation plan** | doc | — |
| `hardware/src/trace/ARCHITECTURE.md` | block diagram (Mermaid + ASCII), record format, packing rules | doc | — |
| `hardware/src/trace/instr_tracer_synth_pinout.png` | full module pinout image (generated) | img | — |
| `docs/instr_tracer_synth_arch.pptx` | 12-slide architecture / co-sim deck (generated) | bin | — |
| `scripts/gen_tracer_arch_ppt.py` | regenerate the `.pptx` | tool | — |
| `scripts/gen_tracer_pinout.py` | regenerate the pinout `.png` | tool | — |

## Updated files
| File | Change |
|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | added `vec_commit_log_pkt_t` (+ `VlW`) — additive, scalar record unchanged |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | print the Spike vector line (de-shuffle via `ara_pkg::shuffle_index`); suppress the duplicate scalar line; program-order merge |
| `hardware/tb/instr_tracer_synth_tap.sv` | tie off the new sink vector port (scalar-only `ariane` bind) |
| `hardware/tb/tb_ara_system_trace.sv` | wire the vector tracer (taps `i_ariane.*` + `i_ara.{i_dispatcher, gen_lanes[L].i_lane}.*`) |
| `scripts/compare_spike_log.py` | `--no-vreg` / `--no-vec` bring-up flags for vector lines |

(Unchanged: `instr_tracer_synth.sv`, `instr_tracer_addr_fifo.sv`, `instr_tracer_synth_bind.sv`,
`spike_trace_decode.py`, `README.md`, `TUTORIAL.md`, `RISCV_DV.md`.)

## Status
- **Vector path: implemented but NOT yet simulated** (no Verilator/QuestaSim build was
  available). The Spike format, the VRF byte-order de-shuffle, and the addressing are
  derived from the Ara source, but the hierarchical taps, the `AddrInBank` assumption,
  and the timing/ordering need a sim pass — see `VECTOR.md` §6.
- Coverage v1: single-register destinations at `EEW = vtype.vsew` (common OP-V
  arithmetic + unit-stride loads, `LMUL = 1`). TODOs in `VECTOR.md` §5
  (`LMUL>1`, widening, scalar-writing moves, vector stores, `vset` CSR tokens).
- `.pptx` / `.png` are **generated artifacts** (regenerable via the `scripts/gen_*` files).
