# trace_cva6_synth

A **synthesizable** instruction (commit) tracer for the **CVA6** core, designed
as a hardware-implementable re-creation of CVA6's simulation-only `instr_tracer`.
It captures retired instructions and reproduces the **Spike commit-log** format
(the `trace_hart_<id>_commit.log` produced by `riscv::spikeCommitLog`), using
only synthesizable SystemVerilog for the on-chip capture.

For the **simulation** flow the sink **prints the commit log directly in
SystemVerilog** (just like the original tracer) — no Python needed. For a **real
silicon** stream you can instead pack the records to binary and decode them
off-chip with the included Python script (the same split the Verilator flow uses
with `spike-dasm`).

> Developed against the [pulp-platform/ara](https://github.com/pulp-platform/ara)
> project (CVA6 + Ara vector unit). File paths below mirror where each file is
> meant to live inside the Ara tree.

## What's inside

| File | Role | Synthesizable |
|---|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | Packed trace record (`commit_log_pkt_t` / `commit_log_beat_t`, incl. mem fields) | ✅ |
| `hardware/src/trace/instr_tracer_addr_fifo.sv` | Small push≤1 / pop≤2 / flush FIFO that re-aligns LSU load/store addresses to commit | ✅ |
| `hardware/src/trace/instr_tracer_synth.sv` | The tracer module: capture commit, result mux, shadow regfile, load/store addr FIFOs, pack, output FIFO, ready/valid out | ✅ |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | Sim-only sink: **prints the Spike commit log directly in SystemVerilog** (`spike_commit_str()` + `$fwrite`) to `trace_hart_<id>_commit.synth.log`; optional hex dump (`EmitPktHex=1`) for the silicon path | ❌ (sim) |
| `hardware/tb/instr_tracer_synth_tap.sv` | Sim-only wrapper bundling tracer + sink | ❌ (sim) |
| `hardware/tb/instr_tracer_synth_bind.sv` | `bind` onto the CVA6 `ariane` core (non-invasive) | ❌ (sim) |
| `hardware/tb/tb_ara_system_trace.sv` | Example testbench: instantiate `ara_system`, connect AXI memory, drive the tracer + sink | ❌ (sim) |
| `scripts/spike_trace_decode.py` | Optional host decoder: binary records → Spike / riscv-dv commit log (silicon path) | (Python) |
| `hardware/src/trace/{README,TUTORIAL,RISCV_DV}.md` | Design, simulation tutorial, riscv-dv co-sim flow | — |
| `INTEGRATION_CVA6.md` | How to drop the files into any CVA6 project (init, signal wiring, run) | — |

## How it works

```
                         ┌──────── SIMULATION ────────┐
   ON-CHIP (synthesizable)│        sink (SV)           │
   ──────────────────────│  spike_commit_str()+$fwrite│→ trace_hart_0_commit.synth.log
   capture commit + pack →│  (no Python needed)        │
   (instr_tracer_synth.sv)└────────────────────────────┘
            │             ┌──────── REAL SILICON ──────┐
            └── FIFO ─────│  ready/valid → UART/AXI →   │→ binary stream
              (binary)    │  spike_trace_decode.py (host)│→ Spike commit log
                          └────────────────────────────┘
```

The simulation-only tracer is not synthesizable because it uses classes, dynamic
queues (`[$]`), strings, `$sformatf`/`$fwrite`, and clocking blocks. Here the
on-chip capture maps to: packed structs, a fixed-depth FIFO, a fixed-layout
binary record, and a ready/valid streaming port. The ASCII formatting stays
where it belongs — in a sim-only `$fwrite` (the sink) or an off-chip script.

## Output format (Spike commit-log style)

```
3 0x0000000080000000 (0x00000297) x 5 0x0000000080000000
3 0x0000000080000004 (0x00500513) x10 0x0000000000000005
3 0x0000000080000008 (0x00008067)
3 0x0000000080002000 (0x00b53023) mem 0x0000000080003000 0xdeadbeefcafe1234
3 0x0000000080002004 (0x0085b503) x10 0x000000000000000f mem 0x0000000080003000 0x000000000000000f
```
`<priv> 0x<pc:16hex> (0x<instr>) [<x|f><rd> 0x<value:16hex>] [mem 0x<addr> 0x<data>]`
— one line per retired instruction. The register field is omitted when nothing is
written back; the `mem` token (address + data, data sized to the access width) is
appended for loads and stores.

## Integrating into a CVA6 / Ara project

See `INTEGRATION_CVA6.md` for the full guide. In short, drop the files into the
tree and add them to the test compile target (order: package → module → sink →
tap → bind), e.g. in Ara's `Bender.yml`:

```yaml
    - target: ara_test
      files:
        - hardware/src/trace/instr_tracer_synth_pkg.sv
        - hardware/src/trace/instr_tracer_addr_fifo.sv
        - hardware/src/trace/instr_tracer_synth.sv
        - hardware/src/trace/instr_tracer_synth_sink.sv
        - hardware/tb/instr_tracer_synth_tap.sv
        - hardware/tb/instr_tracer_synth_bind.sv
        # ... existing ara_testharness.sv / ara_tb.sv ...
```

The `bind` attaches the tracer to every CVA6 `ariane` instance, so the CVA6
submodule itself is left untouched.

## Run (simulation) and check

```bash
# build & run the CVA6/Ara sim (QuestaSim flow), then:
cd hardware/build
diff trace_hart_0_commit.log trace_hart_0_commit.synth.log && echo "MATCH"
```
An empty `diff` means the synthesizable tracer reproduces the original tracer's
Spike commit log byte-for-byte.

## Optional: silicon binary path (Python decoder)

Set `EmitPktHex=1` on the sink to also dump raw packed records, then decode:
```bash
python3 scripts/spike_trace_decode.py trace_hart_0.pkt.hex            # Spike commit log
python3 scripts/spike_trace_decode.py --format spike trace_hart_0.pkt.hex  # riscv-dv compatible
```
