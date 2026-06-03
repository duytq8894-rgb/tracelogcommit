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

endpackage : instr_tracer_synth_pkg
