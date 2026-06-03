// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Synthesizable instruction (commit) tracer for the CVA6 core.
//
// This is a hardware-implementable re-creation of the simulation-only
// `instr_tracer`. It observes the *same* commit-stage signals and reproduces
// the *same* information that feeds `riscv::spikeCommitLog()`, but it does so
// using only synthesizable constructs:
//
//   simulation tracer (NOT synthesizable)   ->  this module (synthesizable)
//   ---------------------------------------     -----------------------------
//   SystemVerilog classes / `new`           ->  packed structs
//   dynamic queues  logic[..][$]            ->  a fixed-depth hardware FIFO
//   string + $sformatf                      ->  fixed-layout binary record
//   $fopen / $fwrite / $fclose              ->  ready/valid streaming port
//   interface + clocking block              ->  plain module ports
//   initial / forever / task                ->  always_ff / always_comb
//
// The on-chip part only *captures and packs* retired instructions. Turning the
// binary stream into Spike-format ASCII text is done off-chip by
// `scripts/spike_trace_decode.py`, the same division of labour the Verilator
// flow uses with `spike-dasm`.

module instr_tracer_synth import ariane_pkg::*; import instr_tracer_synth_pkg::*; #(
  // Depth of the on-chip trace buffer. One entry holds one cycle's worth of
  // committed instructions (up to NR_COMMIT_PORTS of them).
  parameter int unsigned FifoDepth = 32
) (
  input  logic                                          clk_i,
  input  logic                                          rst_ni,
  input  logic                                          flush_i,      // drop buffered trace
  input  logic                                          testmode_i,   // FIFO clk-gate bypass

  // ----------------------- commit-stage observation -----------------------
  // All inputs are packed structs / vectors, i.e. fully synthesizable. They map
  // 1:1 onto the assigns that drive `tracer_if` in ariane.sv.
  input  scoreboard_entry_t [NR_COMMIT_PORTS-1:0]       commit_instr_i, // retiring instr
  input  logic              [NR_COMMIT_PORTS-1:0]       commit_ack_i,   // it retires now
  // Raw instruction word of the retiring instruction. In CVA6 the decoder
  // stashes it into `commit_instr_i[p].ex.tval[31:0]` when no exception is
  // pending, so the integrator can simply tie this to that field (this is what
  // the Verilator DASM mock does). A dedicated commit-stage instruction-word
  // register is preferred when available.
  input  logic              [NR_COMMIT_PORTS-1:0][31:0] instr_word_i,
  // architectural write-back bus
  input  logic              [NR_COMMIT_PORTS-1:0][4:0]            waddr_i,
  input  logic              [NR_COMMIT_PORTS-1:0][riscv::XLEN-1:0] wdata_i,
  input  logic              [NR_COMMIT_PORTS-1:0]                  we_gpr_i,
  input  logic              [NR_COMMIT_PORTS-1:0]                  we_fpr_i,
  // status
  input  riscv::priv_lvl_t                              priv_lvl_i,
  input  logic                                          debug_mode_i,
  input  exception_t                                    exception_i,

  // ----------------------- streaming trace-out port ------------------------
  // A standard ready/valid handshake. Connect to a UART, an AXI DMA, a debug
  // trace port, an on-chip buffer, ... Off-chip, feed the captured beats to the
  // host decoder.
  output logic                                          trace_valid_o,
  output commit_log_beat_t                              trace_beat_o,
  input  logic                                          trace_ready_i,
  // Pulses high whenever a beat had to be dropped because the FIFO was full.
  // Lets the consumer know the trace is no longer gap-free.
  output logic                                          overflow_o
);

  // ---------------------------------------------------------------------------
  // Shadow architectural register files (synthesizable register arrays).
  //
  // Mirrors the gp_reg_file / fp_reg_file shadow copies of the simulation
  // tracer. They are needed only to recover the committed value of an
  // instruction whose result is not presented on the write-back bus in the same
  // cycle (Spike still prints the destination register's current value).
  // ---------------------------------------------------------------------------
  logic [riscv::XLEN-1:0] gp_reg_file_q [32];
  logic [riscv::XLEN-1:0] fp_reg_file_q [32];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned r = 0; r < 32; r++) begin
        gp_reg_file_q[r] <= '0;
        fp_reg_file_q[r] <= '0;
      end
    end else begin
      for (int unsigned p = 0; p < NR_COMMIT_PORTS; p++) begin
        // x0 is hard-wired to zero, never shadow it.
        if (we_gpr_i[p] && (waddr_i[p] != 5'd0)) begin
          gp_reg_file_q[waddr_i[p]] <= wdata_i[p];
        end else if (we_fpr_i[p]) begin
          fp_reg_file_q[waddr_i[p]] <= wdata_i[p];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Build one trace beat combinationally from the current commit signals.
  // ---------------------------------------------------------------------------
  commit_log_beat_t beat;

  always_comb begin
    beat = '0;
    for (int unsigned p = 0; p < NR_COMMIT_PORTS; p++) begin
      automatic logic [4:0]            rd;
      automatic logic                  wb;
      automatic logic                  rd_is_fpr;
      automatic logic [riscv::XLEN-1:0] result;

      rd        = commit_instr_i[p].rd[4:0];
      wb        = we_gpr_i[p] | we_fpr_i[p];
      rd_is_fpr = is_rd_fpr(commit_instr_i[p].op);

      // Result selection mirrors the simulation tracer exactly:
      //   - take the write-back data when the register is written this cycle;
      //   - otherwise read the shadow register file (most recent value).
      if (wb)             result = wdata_i[p];
      else if (rd_is_fpr) result = fp_reg_file_q[rd];
      else                result = gp_reg_file_q[rd];

      beat.pkt[p].priv       = priv_lvl_i;
      beat.pkt[p].debug      = debug_mode_i;
      beat.pkt[p].ex_valid   = 1'b0;
      beat.pkt[p].compressed = commit_instr_i[p].is_compressed;
      beat.pkt[p].we         = wb;
      beat.pkt[p].rd_fpr     = rd_is_fpr;
      beat.pkt[p].rd         = rd;
      beat.pkt[p].pc         = commit_instr_i[p].pc;
      beat.pkt[p].instr      = instr_word_i[p];
      beat.pkt[p].wdata      = result;
      beat.pkt[p].cause      = '0;
      beat.pkt[p].tval       = '0;

      beat.valid[p] = commit_ack_i[p];
    end

    // An exception / interrupt is always reported against the oldest port
    // (port 0), identical to the simulation tracer (commit_instr[0].pc). The
    // debug-mode breakpoint is suppressed exactly as upstream does.
    if (exception_i.valid &&
        !(debug_mode_i && (exception_i.cause == riscv::BREAKPOINT))) begin
      beat.pkt[0].ex_valid = 1'b1;
      beat.pkt[0].pc       = commit_instr_i[0].pc;
      beat.pkt[0].cause    = exception_i.cause;
      beat.pkt[0].tval     = exception_i.tval;
      beat.valid[0]        = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Buffer the beats in a hardware FIFO and expose them on a ready/valid port.
  // ---------------------------------------------------------------------------
  logic any_valid, full, empty;
  assign any_valid = |beat.valid;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0              ),
    .dtype        ( commit_log_beat_t ),
    .DEPTH        ( FifoDepth         )
  ) i_trace_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .testmode_i,
    .full_o     ( full          ),
    .empty_o    ( empty         ),
    .usage_o    ( /* unused */  ),
    .data_i     ( beat          ),
    .push_i     ( any_valid & ~full ),
    .data_o     ( trace_beat_o  ),
    .pop_i      ( trace_valid_o & trace_ready_i )
  );

  assign trace_valid_o = ~empty;
  // A beat is produced but the buffer is full -> it is lost. Flag it so the
  // off-chip side knows the trace has a gap (it cannot be reconstructed).
  assign overflow_o    = any_valid & full;

endmodule : instr_tracer_synth
