# trace_cva6_synth

A **synthesizable** instruction (commit) tracer for the **CVA6** core, designed
as a hardware-implementable re-creation of CVA6's simulation-only `instr_tracer`.
It captures retired instructions and reproduces the **Spike commit-log** format,
but uses only synthesizable SystemVerilog — the ASCII formatting is moved
off-chip to a Python decoder (the same split the Verilator flow uses with
`spike-dasm`).

> Developed against the [pulp-platform/ara](https://github.com/pulp-platform/ara)
> project (CVA6 + Ara vector unit). File paths below mirror where each file is
> meant to live inside the Ara tree.

## What's inside

| File | Role | Synthesizable |
|---|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | Packed binary trace record (`commit_log_pkt_t` / `commit_log_beat_t`) | ✅ |
| `hardware/src/trace/instr_tracer_synth.sv` | The tracer module: capture commit, result mux, shadow regfile, pack, FIFO, ready/valid out | ✅ |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | Simulation-only sink that dumps packed hex records | ❌ (sim) |
| `hardware/tb/instr_tracer_synth_tap.sv` | Sim-only wrapper bundling tracer + sink | ❌ (sim) |
| `hardware/tb/instr_tracer_synth_bind.sv` | `bind` onto the CVA6 `ariane` core (non-invasive) | ❌ (sim) |
| `scripts/spike_trace_decode.py` | Host decoder: binary → Spike / riscv-dv commit log | (Python) |

## How it works

```
   ON-CHIP (synthesizable)            OFF-CHIP (host)
   ──────────────────────            ────────────────
   capture commit + pack binary  →   decode binary → Spike-format ASCII
   (instr_tracer_synth.sv)           (spike_trace_decode.py)
```

The simulation-only tracer is not synthesizable because it uses classes, dynamic
queues (`[$]`), strings, `$sformatf`/`$fwrite`, and clocking blocks. Here those
map to: packed structs, a fixed-depth FIFO, a fixed-layout binary record, and a
ready/valid streaming port respectively.

## Docs

- `hardware/src/trace/README.md` — design and field-by-field format (Vietnamese)
- `hardware/src/trace/TUTORIAL.md` — build & simulate with the CVA6 core, then
  diff the decoded log against the original tracer's golden Spike log
- `hardware/src/trace/RISCV_DV.md` — co-simulation flow: riscv-dv generator +
  Spike ISS reference + this tracer as the DUT trace, compared with riscv-dv

## Integrating into Ara

Drop the files into the Ara tree at the paths shown above, then add them to the
`ara_test` target in `Bender.yml` (order matters — package, module, then the
sim-only tap/bind):

```yaml
    - target: ara_test
      files:
        - hardware/src/trace/instr_tracer_synth_pkg.sv
        - hardware/src/trace/instr_tracer_synth.sv
        - hardware/src/trace/instr_tracer_synth_sink.sv
        - hardware/tb/instr_tracer_synth_tap.sv
        - hardware/tb/instr_tracer_synth_bind.sv
        # ... existing ara_testharness.sv / ara_tb.sv ...
```

The `bind` attaches the tracer to every CVA6 `ariane` instance, so the CVA6
submodule itself is left untouched.

## Quick decoder self-check

```bash
# packed hex records (one commit_log_pkt_t per line) -> Spike commit log
python3 scripts/spike_trace_decode.py trace_hart_00.pkt.hex
# riscv-dv compatible (drop-in for spike_log_to_trace_csv.py)
python3 scripts/spike_trace_decode.py --format spike trace_hart_00.pkt.hex
```
