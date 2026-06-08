# `instr_tracer_synth` — Internal microarchitecture

A detailed, easy-to-follow view of the synthesizable instruction tracer: how one
cycle of committed instructions becomes a packed trace **beat** that is buffered
and streamed off-chip. Everything below is synthesizable RTL
([instr_tracer_synth.sv](instr_tracer_synth.sv)); the record format lives in
[instr_tracer_synth_pkg.sv](instr_tracer_synth_pkg.sv).

---

## 0. Module pinout (every input / output pin)

![instr_tracer_synth module pinout](instr_tracer_synth_pinout.png)

Inputs on the left (grouped: clock/reset/control · commit-stage observation · CSR
write observation · LSU memory-access observation); the streaming trace-out
`ready/valid` port on the right. `[w]` is the bit width; `sbe` =
`scoreboard_entry_t`, `exc_t` = `exception_t`, `beat_t` = `commit_log_beat_t`.
Re-render with `python3 scripts/gen_tracer_pinout.py`.

---

## 1. Block diagram — the beat builder and its two memories

The heart is one combinational **beat builder**. It reads the live commit-stage
signals plus two on-chip memory structures — a **shadow regfile** (to recover a
register's value) and **address FIFOs** (to realign out-of-order LSU addresses) —
and emits one packed beat, which a FIFO buffers and a `ready/valid` port streams out.

```mermaid
flowchart TB
    %% live commit-stage signals + the two buses that fill the memories
    WB["write-back bus<br/>waddr · wdata · we_gpr / we_fpr"]
    SIG["<b>commit-stage signals</b> · 2 ports / cycle<br/>commit_instr · instr_word · commit_ack<br/>priv · debug · exception_i · csr_*"]
    LSU["LSU addresses<br/>st_* · ld_*"]

    %% the two memory structures the builder reads from
    SHADOW[("<b>Shadow regfile</b><br/>gp / fp_reg_file_q[32]<br/>recovers rd's value")]
    AFIFO[("<b>Address FIFOs</b> · store + load<br/>depth 16 · byte_ror64<br/>realign addr → commit order")]

    %% the heart: combinational packer
    BEAT["<b>BEAT BUILDER</b> · always_comb<br/>per-port packet + port-0 exception / CSR<br/>→ commit_log_beat_t"]

    %% straight backbone out
    TFIFO["<b>Trace FIFO</b><br/>fifo_v3 · depth 32"]
    OUT["<b>Trace-out port</b><br/>ready / valid"]
    OVF(["overflow_o<br/>FIFO full → trace gap"])

    WB  --> SHADOW
    LSU --> AFIFO
    SIG --> BEAT
    SHADOW -->|"reg[rd]"| BEAT
    AFIFO  -->|"mem addr / data / size"| BEAT
    BEAT -.->|"pop @ commit"| AFIFO
    BEAT --> TFIFO --> OUT
    TFIFO -.->|"full"| OVF

    classDef sig  fill:#E9ECF1,stroke:#1F3A5F,color:#1F3A5F;
    classDef mem  fill:#FCEFD9,stroke:#C4761C,color:#5A3208;
    classDef beat fill:#C9DEF7,stroke:#2E6DB4,stroke-width:2px,color:#1F3A5F;
    classDef proc fill:#DCEAFB,stroke:#2E6DB4,color:#1F3A5F;
    classDef warn fill:#FDDDD6,stroke:#C84A33,color:#7A1D0C;
    class WB,SIG,LSU sig;
    class SHADOW,AFIFO mem;
    class BEAT beat;
    class TFIFO,OUT proc;
    class OVF warn;
```

**What each block does**

| Block | Role | Why it's there |
|-------|------|----------------|
| **Shadow regfile** `gp/fp_reg_file_q[32]` | mirrors the latest value of every register (`always_ff`) | Spike prints `rd`'s value even when it isn't on the write-back bus this cycle |
| **Address FIFOs** + `byte_ror64` | buffer LSU addresses, popped at commit | the LSU generates addresses **out of program order**; the FIFO realigns each to the retiring instruction |
| **Beat builder** (`always_comb`) | pack one record per port + port-0 exception / CSR → `commit_log_beat_t` | one record per retired instruction, in program order |
| **Trace FIFO** (`fifo_v3`, depth 32) | buffer finished beats | absorb back-pressure from the trace-out port |
| **Trace-out port** (`ready`/`valid`) | stream beats off-chip | connect to UART / AXI-DMA / debug port / on-chip buffer |

---

## 2. ASCII block diagram (same thing, no Mermaid needed)

```
 write-back bus      commit-stage signals · 2 ports/cycle        LSU addresses
 waddr·wdata·we_*    commit_instr · instr_word · commit_ack      st_* · ld_*
                     priv · debug · exception_i · csr_*
        │                              │                               │
        ▼                              ▼                               ▼
┌───────────────┐           ┌─────────────────────┐           ┌─────────────────┐
│ Shadow regfile│           │    BEAT BUILDER     │           │ Address FIFOs   │
│ gp/fp_q[32]   │──reg[rd]─►│ (always_comb)       │◄─── mem ──│ store + load    │
│               │           │ per-port packet     │─── pop ──►│ depth 16        │
│ recovers rd's │           │ + port-0            │           │ + byte_ror64    │
│ value when not│           │ exception / CSR     │           │ realign LSU     │
│ on the WB bus │           │                     │           │ addr → commit   │
└───────────────┘           └──────────┬──────────┘           └─────────────────┘
                                       ▼
                          ┌─────────────────────────┐
                          │ Trace FIFO              │ ──full──►  overflow_o
                          │ fifo_v3 · depth 32      │
                          └────────────┬────────────┘
                                       ▼
                          ┌─────────────────────────┐
                          │ Trace-out port          │
                          │ ready / valid           │
                          └─────────────────────────┘
```

---

## 3. What goes into one trace record

A **beat** keeps both commit ports of one cycle together so program order survives
the FIFO (port 0 is the older instruction).

```mermaid
flowchart TB
    BEAT["<b>commit_log_beat_t</b><br/>valid[NR_COMMIT_PORTS] + 2 × commit_log_pkt_t"]
    P0["<b>commit_log_pkt_t</b> — port 0 (older)"]
    P1["<b>commit_log_pkt_t</b> — port 1"]
    BEAT --> P0
    BEAT --> P1
    classDef b fill:#E9ECF1,stroke:#1F3A5F,color:#1F3A5F;
    classDef p fill:#DCEAFB,stroke:#2E6DB4,color:#1F3A5F;
    class BEAT b;
    class P0,P1 p;
```

Each `commit_log_pkt_t` (≈300 bits @ XLEN=64, packed MSB-first):

| Group | Fields |
|-------|--------|
| **Identity** | `priv` · `debug` · `retired` · `compressed` · `rd` (+`rd_fpr`) · `pc` · `instr` |
| **Result** | `we` · `wdata` |
| **Exception** | `ex_valid` · `cause` · `tval` |
| **Memory** | `mem_op` · `mem_addr` · `mem_data` · `mem_size` |
| **CSR write** | `csr_we` · `csr_addr` · `csr_wdata` |

These are exactly the fields `riscv::spikeCommitLog()` consumes — the host decoder
(or the sim sink) turns them back into Spike-format ASCII.

---

## 4. The 3 packing rules (how fields are filled)

**Rule 1 — result value (a 3-way mux), per port**

```text
if (we_gpr | we_fpr)   result = wdata_i            // written this cycle
else if (rd is FPR)    result = fp_reg_file_q[rd]   // shadow FP regfile
else                   result = gp_reg_file_q[rd]   // shadow GP regfile
```

**Rule 2 — memory token (`mem 0x..`), only when the instruction commits**

```text
STORE (non-AMO) → MEM_STORE, pop store FIFO, data = byte_ror64(fifo.data)
LOAD            → MEM_LOAD  (up to 2 loads/cycle), addr from load FIFO
otherwise       → MEM_NONE
```
> AMOs report `fu == STORE` but never push the store buffer, so they must **not**
> pop the store FIFO (keeps it aligned).

**Rule 3 — port-0-only overrides (always on the older port 0)**

```text
exception.valid & !(debug & BREAKPOINT) → ex_valid, cause, tval
csr_commit & op ∈ {WRITE, SET, CLEAR}    → csr_we, reconstruct csr_wdata
                                            (SET: op|old, CLEAR: ~op&old, WRITE: op)
```

---

## 5. Back-pressure & overflow

The trace-out port is a standard `ready/valid` handshake. If the consumer stalls
and the trace FIFO fills, the produced beat is dropped and `overflow_o` pulses to
flag that the trace is **no longer gap-free**. The address FIFOs raise it too on
over/underflow (a `mem` token could be misaligned). Raise `FifoDepth` or widen the
output bandwidth to avoid it.

---

*Generated companion to [README.md](README.md) and [TUTORIAL.md](TUTORIAL.md).*
