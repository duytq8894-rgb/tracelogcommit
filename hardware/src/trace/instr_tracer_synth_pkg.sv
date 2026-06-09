// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Synthesizable instruction-trace record format.
//
// The simulation-only `instr_tracer` produces a Spike-compatible commit log by
// formatting ASCII strings ($sformatf) and writing them to a file ($fwrite).
// Neither strings nor file I/O can be synthesized. This package defines the
// *same information* as a fixed-layout packed struct that can live in real
// flip-flops and be streamed off-chip. The ASCII Spike formatting is done by a
// host-side decoder (scripts/spike_trace_decode.py), exactly the way the
// Verilator flow offloads disassembly to `spike-dasm`.

package instr_tracer_synth_pkg;

  // Architectural data-path width (PC / GPR / FPR width) and the number of
  // instructions that may retire in the same clock cycle. Sourced from the
  // CVA6 packages so the record always matches the core configuration.
  localparam int unsigned XLEN          = riscv::XLEN;
  localparam int unsigned NrCommitPorts = ariane_pkg::NR_COMMIT_PORTS;

  // ---------------------------------------------------------------------------
  // One retired-instruction record.
  //
  // Carries exactly the fields that `riscv::spikeCommitLog()` consumes:
  //   priv, pc, instr, rd (+fpr flag), result   plus the exception fields used
  // by the human-readable trace. Packed MSB-first in declaration order.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]      priv;        // privilege level (riscv::priv_lvl_t: M=3,S=1,U=0)
    logic            debug;       // core was in debug mode when it retired
    logic            ex_valid;    // an exception / interrupt was reported here
    logic            retired;     // port committed (commit_ack): a commit-log line is due
    logic            compressed;  // RVC (16-bit) instruction
    logic            we;          // an architectural register was written back
    logic            rd_fpr;      // destination register is a FP register
    logic [4:0]      rd;          // destination register index
    logic [XLEN-1:0] pc;          // program counter of the instruction
    logic [31:0]     instr;       // raw (possibly compressed) instruction word
    logic [XLEN-1:0] wdata;       // committed result / write-back value
    logic [XLEN-1:0] cause;       // exception cause   (valid when ex_valid)
    logic [XLEN-1:0] tval;        // trap value        (valid when ex_valid)
    // Memory access info for load/store (Spike-style "mem 0x<addr> 0x<data>").
    logic [1:0]      mem_op;      // MEM_NONE / MEM_LOAD / MEM_STORE
    logic [63:0]     mem_addr;    // physical address of the access (zero-extended)
    logic [63:0]     mem_data;    // value loaded/stored
    logic [1:0]      mem_size;    // access size: 0=byte,1=half,2=word,3=dword
    // CSR write info (Spike-style "c<addr> 0x<value>").
    logic            csr_we;      // a CSR was written (csrrw/csrrs/csrrc)
    logic [11:0]     csr_addr;    // CSR address
    // value written, reconstructed at commit = post-op but PRE per-CSR WARL mask
    // (and, for mip/sip SET/CLEAR, the old value is the SEIP-OR'd csr_rdata_o).
    // So for WARL CSRs (mstatus, m/stvec, m/sepc, satp, mip/mie, pmp*, *counteren,
    // ...) this differs from Spike's post-WARL value; an exact match would need a
    // post-WARL read-back from csr_regfile (an invasive CVA6 change).
    logic [XLEN-1:0] csr_wdata;
  } commit_log_pkt_t;

  // mem_op encoding
  localparam logic [1:0] MEM_NONE  = 2'd0;
  localparam logic [1:0] MEM_LOAD  = 2'd1;
  localparam logic [1:0] MEM_STORE = 2'd2;

  // ---------------------------------------------------------------------------
  // One "trace beat": all commit ports of a single cycle kept together so that
  // program order is preserved through the FIFO. Port 0 is the older (earlier
  // in program order) instruction, identical to the CVA6 commit convention.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic            [NrCommitPorts-1:0] valid; // which ports retired this beat
    commit_log_pkt_t [NrCommitPorts-1:0] pkt;   // the per-port records
  } commit_log_beat_t;

  // Handy widths for testbenches / off-chip decoders.
  localparam int unsigned PktWidth  = $bits(commit_log_pkt_t);
  localparam int unsigned BeatWidth = $bits(commit_log_beat_t);

  // ===========================================================================
  // Vector (RVV) commit-log record  --  feature: log Ara vector instructions in
  // Spike commit-log format.  Per hardware/src/trace/trace_vector.md, the sink
  // prints, for a vector instruction that writes a vector register:
  //
  //   <priv> 0x<pc> (0x<insn>) v<vd> 0x<VLEN-bit hex>
  //
  // (vsew/vlmul/vl are still captured below -- vsew drives the de-shuffle EEW and
  //  all three remain available in the raw packet dump -- but the targeted Spike
  //  version prints only the bare v<vd> token, with no e<sew>/<lmul>/l<vl> summary.)
  //
  // The scalar half retires in CVA6 (fu == ACCEL); the destination data lives in
  // Ara's VRF, striped across the lanes (see ara_pkg shuffle_index). We capture
  // a *raw* (lane-shuffled) snapshot of v[vd] here, and the off-chip / sim sink
  // de-shuffles it with ara_pkg::shuffle_index before formatting, so the bytes
  // match the DUT by construction.
  // ---------------------------------------------------------------------------
  // NB: reference ara_pkg::VLEN fully-qualified so this package does NOT export a
  // `VLEN`/`VLENB` symbol (that would collide with ara_pkg under a dual `import *`).
  localparam int unsigned VlW = $clog2(ara_pkg::VLEN + 1);  // vl is an element count (<= MAXVL = VLEN)

  typedef struct packed {
    logic                     valid;  // a vector-register write committed this cycle
    logic                     first;  // first destination vreg of the instruction (emit the e/m/l token)
    logic                     last;   // last destination vreg of the instruction (flush the commit-log line)
    logic [1:0]               priv;   // privilege level (M=3,S=1,U=0)
    logic                     debug;  // core in debug mode (suppresses the line, like the scalar path)
    logic [XLEN-1:0]          pc;     // program counter of the vector instruction
    logic [31:0]              instr;  // raw instruction word
    logic [2:0]               vsew;   // rvv_pkg::vew_e  (EW8=0,EW16=1,EW32=2,EW64=3) -> e8/e16/e32/e64
    logic [2:0]               vlmul;  // rvv_pkg::vlmul_e -> m1/m2/m4/m8 / mf2/mf4/mf8
    logic [VlW-1:0]           vl;     // vector length (element count) in effect
    logic [4:0]               vd;     // this record's destination vector register
    logic [ara_pkg::VLEN-1:0] data;   // RAW (lane-shuffled) contents of v[vd]; sink de-shuffles by vsew
  } vec_commit_log_pkt_t;

  localparam int unsigned VecPktWidth = $bits(vec_commit_log_pkt_t);

endpackage : instr_tracer_synth_pkg
