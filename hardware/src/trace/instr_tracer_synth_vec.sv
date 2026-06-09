// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Synthesizable VECTOR commit tracer for CVA6 + Ara.
//
// Companion to instr_tracer_synth.sv (which handles scalar commits). A vector
// instruction retires in CVA6 with fu == ACCEL; its destination data lives in
// Ara's VRF. This module:
//   1. mirrors the Ara VRF into a synthesizable shadow (instr_tracer_synth_vrf_shadow),
//   2. at an ACCEL commit that writes a vector register, decodes `vd` from the
//      retired instruction word, reads Ara's current vsew/vlmul/vl, snapshots
//      v[vd] from the shadow, and
//   3. packs a vec_commit_log_pkt_t and streams it out (ready/valid), to be
//      formatted into a Spike commit-log line off-chip / by the sim sink.
//
// COVERAGE (v1) — validate in simulation; see VECTOR.md:
//   * single-register destinations at EEW = vtype.vsew: OP-V arithmetic / mask
//     ops and unit-stride vector loads. (first = last = 1.)
//   * Reductions/moves writing a SCALAR (vmv.x.s, vcpop.m, vfirst.m, vfmv.f.s)
//     are correctly EXCLUDED here (writes_vreg) and emitted by the scalar path
//     as x/f<rd> (trace_vector.md §3.10).
//   * NOT yet expanded: LMUL>1 (EMUL>1, multiple v<vd> per line), widening
//     (2*SEW dest), mask-result EEW (de-shuffle uses vtype.vsew), and the exact
//     vtype/vl of an instruction still in flight (we read Ara's *current* CSRs,
//     like the scalar shadow regfile reads "most recent").

// (ara_pkg referenced fully-qualified to avoid a VLEN name clash with
//  instr_tracer_synth_pkg under dual import.)
module instr_tracer_synth_vec import ariane_pkg::*; import instr_tracer_synth_pkg::*; #(
  parameter int unsigned NrLanes   = 4,
  parameter int unsigned FifoDepth = 4,
  parameter bit          AddrInBank = 1'b1,
  // --- derived ---
  localparam int unsigned NrBanks      = ara_pkg::NrVRFBanksPerLane,
  localparam int unsigned WordsPerReg  = ara_pkg::VLEN / (64 * NrLanes),
  localparam int unsigned WordsPerLane = 32 * WordsPerReg,
  localparam int unsigned GwW          = (WordsPerLane > 1) ? $clog2(WordsPerLane) : 1
) (
  input  logic                                          clk_i,
  input  logic                                          rst_ni,
  input  logic                                          flush_i,
  input  logic                                          testmode_i,

  // ----------------------- commit-stage observation -----------------------
  input  scoreboard_entry_t [NR_COMMIT_PORTS-1:0]       commit_instr_i, // .fu / .pc
  input  logic              [NR_COMMIT_PORTS-1:0]       commit_ack_i,
  input  logic              [NR_COMMIT_PORTS-1:0][31:0] instr_word_i,   // = ex.tval[31:0]
  input  riscv::priv_lvl_t                              priv_lvl_i,
  input  logic                                          debug_mode_i,

  // ----------------------- Ara vtype / vl ---------------------------------
  input  logic              [2:0]                       vsew_i,         // rvv_pkg::vew_e
  input  logic              [2:0]                       vlmul_i,        // rvv_pkg::vlmul_e
  input  logic              [VlW-1:0]                   vl_i,

  // ----------------------- Ara VRF write observation ----------------------
  input  logic [NrLanes-1:0][NrBanks-1:0]               vrf_wen_i,
  input  logic [NrLanes-1:0][NrBanks-1:0][GwW-1:0]      vrf_addr_i,
  input  logic [NrLanes-1:0][NrBanks-1:0][63:0]         vrf_wdata_i,
  input  logic [NrLanes-1:0][NrBanks-1:0][7:0]          vrf_be_i,

  // ----------------------- streaming trace-out ----------------------------
  output logic                                          vec_trace_valid_o,
  output vec_commit_log_pkt_t                           vec_trace_beat_o,
  input  logic                                          vec_trace_ready_i,
  output logic                                          overflow_o
);

  // ---- shadow VRF -----------------------------------------------------------
  logic [4:0]      snap_vid;
  logic [VLEN-1:0] snap_data;

  instr_tracer_synth_vrf_shadow #(
    .NrLanes    ( NrLanes    ),
    .AddrInBank ( AddrInBank )
  ) i_vrf_shadow (
    .clk_i,
    .rst_ni,
    .wen_i     ( vrf_wen_i   ),
    .addr_i    ( vrf_addr_i  ),
    .wdata_i   ( vrf_wdata_i ),
    .be_i      ( vrf_be_i    ),
    .rd_vid_i  ( snap_vid    ),
    .rd_data_o ( snap_data   )
  );

  // ---- decode: does this committing ACCEL instruction write a vector reg? ---
  // OP-V (0x57) writes a vector reg EXCEPT:
  //   * OPCFG (funct3==111): vset* writes x<rd> + vtype/vl CSRs (scalar path).
  //   * VWXUNARY0/VWFUNARY0 (funct6==010000 with funct3 OPMVV=010 / OPFVV=001):
  //       vmv.x.s / vcpop.m / vfirst.m / vfmv.f.s write x/f<rd>, NOT a vreg, so
  //       they must go down the scalar path (trace_vector.md §3.10). funct6==010000
  //       with OPMVX=110 / OPFVF=101 (vmv.s.x / vfmv.s.f) DO write a vreg -- kept.
  // Vector unit-stride loads use the LOAD-FP major opcode (0x07). Stores (0x27)
  // write no vreg. NB: this decode mirrors vec_handled() in the sink -- keep both
  // in sync.
  function automatic logic writes_vreg(logic [31:0] insn);
    automatic logic [6:0] opcode = insn[6:0];
    automatic logic [2:0] funct3 = insn[14:12];
    automatic logic [5:0] funct6 = insn[31:26];
    automatic logic       opv_scalar_dst = (funct6 == 6'b010000)
                                         && (funct3 == 3'b010 || funct3 == 3'b001);
    writes_vreg = (opcode == 7'b1010111 && funct3 != 3'b111 && !opv_scalar_dst) // OP-V vreg dst
                | (opcode == 7'b0000111);                                       // vector load
  endfunction

  // ---- build one vector record from the current commit signals --------------
  vec_commit_log_pkt_t vbeat;

  always_comb begin
    vbeat    = '0;
    snap_vid = '0;
    // pick the first retiring ACCEL port that writes a vector register
    for (int unsigned p = 0; p < NR_COMMIT_PORTS; p++) begin
      if (!vbeat.valid && commit_ack_i[p] && commit_instr_i[p].fu == ACCEL
          && writes_vreg(instr_word_i[p])) begin
        snap_vid       = instr_word_i[p][11:7];      // vd
        vbeat.valid    = 1'b1;
        vbeat.first    = 1'b1;                        // v1: single destination register
        vbeat.last     = 1'b1;
        vbeat.priv     = priv_lvl_i;
        vbeat.debug    = debug_mode_i;
        vbeat.pc       = commit_instr_i[p].pc;
        vbeat.instr    = instr_word_i[p];
        vbeat.vsew     = vsew_i;
        vbeat.vlmul    = vlmul_i;
        vbeat.vl       = vl_i;
        vbeat.vd       = instr_word_i[p][11:7];
        vbeat.data     = snap_data;                  // raw lane-shuffled v[vd]
      end
    end
  end

  // ---- buffer + ready/valid out ---------------------------------------------
  logic full, empty;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0                 ),
    .dtype        ( vec_commit_log_pkt_t ),
    .DEPTH        ( FifoDepth            )
  ) i_vec_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .testmode_i,
    .full_o  ( full  ),
    .empty_o ( empty ),
    .usage_o ( /* unused */ ),
    .data_i  ( vbeat ),
    .push_i  ( vbeat.valid & ~full ),
    .data_o  ( vec_trace_beat_o ),
    .pop_i   ( vec_trace_valid_o & vec_trace_ready_i )
  );

  assign vec_trace_valid_o = ~empty;
  assign overflow_o        = vbeat.valid & full;   // a vector record had to be dropped

endmodule : instr_tracer_synth_vec
