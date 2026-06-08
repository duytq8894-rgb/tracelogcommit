// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Simulation-only "tap" that wires the synthesizable tracer to its
// sink. It exposes only the commit-stage *observation* inputs, so it can be
// attached to a CVA6 `ariane` core with a single `bind` (see
// instr_tracer_synth_bind.sv) without having to declare intermediate wires in
// the bind statement. NOT part of the synthesizable design.

`ifndef SYNTHESIS
// pragma translate_off
module instr_tracer_synth_tap import ariane_pkg::*; import instr_tracer_synth_pkg::*; #(
  parameter int unsigned FifoDepth = 32,
  parameter logic [63:0]  HartId    = 64'h0
) (
  input  logic                                          clk_i,
  input  logic                                          rst_ni,
  input  scoreboard_entry_t [NR_COMMIT_PORTS-1:0]       commit_instr_i,
  input  logic              [NR_COMMIT_PORTS-1:0]       commit_ack_i,
  input  logic              [NR_COMMIT_PORTS-1:0][31:0] instr_word_i,
  input  logic              [NR_COMMIT_PORTS-1:0][4:0]            waddr_i,
  input  logic              [NR_COMMIT_PORTS-1:0][riscv::XLEN-1:0] wdata_i,
  input  logic              [NR_COMMIT_PORTS-1:0]                  we_gpr_i,
  input  logic              [NR_COMMIT_PORTS-1:0]                  we_fpr_i,
  input  riscv::priv_lvl_t                              priv_lvl_i,
  input  logic                                          debug_mode_i,
  input  exception_t                                    exception_i,
  // CSR write observation (for the Spike-style "c<addr> 0x<value>" token)
  input  logic                                          csr_commit_i,
  input  fu_op                                          csr_op_i,
  input  logic              [11:0]                      csr_waddr_i,
  input  riscv::xlen_t                                  csr_operand_i,
  input  riscv::xlen_t                                  csr_old_i,
  // LSU memory-access observation (for the Spike-style mem token)
  input  logic                                          st_valid_i,
  input  logic              [riscv::PLEN-1:0]           st_paddr_i,
  input  logic              [riscv::XLEN-1:0]           st_data_i,
  input  logic              [1:0]                       st_size_i,
  input  logic                                          ld_valid_i,
  input  logic                                          ld_kill_i,
  input  logic              [riscv::PLEN-1:0]           ld_paddr_i,
  input  logic              [1:0]                       ld_size_i,
  input  logic                                          flush_addr_i
);

  commit_log_beat_t beat;
  logic             valid, ready, overflow;

  // The actual synthesizable tracer (device under test).
  instr_tracer_synth #(.FifoDepth(FifoDepth)) i_tracer (
    .clk_i,
    .rst_ni,
    .flush_i        (1'b0),
    .testmode_i     (1'b0),
    .commit_instr_i (commit_instr_i),
    .commit_ack_i   (commit_ack_i),
    .instr_word_i   (instr_word_i),
    .waddr_i        (waddr_i),
    .wdata_i        (wdata_i),
    .we_gpr_i       (we_gpr_i),
    .we_fpr_i       (we_fpr_i),
    .priv_lvl_i     (priv_lvl_i),
    .debug_mode_i   (debug_mode_i),
    .exception_i    (exception_i),
    .csr_commit_i   (csr_commit_i),
    .csr_op_i       (csr_op_i),
    .csr_waddr_i    (csr_waddr_i),
    .csr_operand_i  (csr_operand_i),
    .csr_old_i      (csr_old_i),
    .st_valid_i     (st_valid_i),
    .st_paddr_i     (st_paddr_i),
    .st_data_i      (st_data_i),
    .st_size_i      (st_size_i),
    .ld_valid_i     (ld_valid_i),
    .ld_kill_i      (ld_kill_i),
    .ld_paddr_i     (ld_paddr_i),
    .ld_size_i      (ld_size_i),
    .flush_addr_i   (flush_addr_i),
    .trace_valid_o  (valid),
    .trace_beat_o   (beat),
    .trace_ready_i  (ready),
    .overflow_o     (overflow)
  );

  // The simulation sink: always ready, dumps packed hex records to a file.
  // This `ariane`-scoped tap handles the SCALAR path only; vector (RVV) logging
  // is system-level (needs Ara) and is wired in tb_ara_system_trace.sv, so the
  // vector port is tied off here.
  instr_tracer_synth_sink #(.HartId(HartId)) i_sink (
    .clk_i,
    .rst_ni,
    .trace_valid_i (valid),
    .trace_beat_i  (beat),
    .trace_ready_o (ready),
    .overflow_i    (overflow),
    .vec_trace_valid_i (1'b0),
    .vec_trace_beat_i  ('0),
    .vec_trace_ready_o (/* open */),
    .vec_overflow_i    (1'b0)
  );

endmodule : instr_tracer_synth_tap
// pragma translate_on
`endif
