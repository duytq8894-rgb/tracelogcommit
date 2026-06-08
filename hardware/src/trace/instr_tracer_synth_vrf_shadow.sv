// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Synthesizable SHADOW copy of Ara's distributed Vector Register
// File, for the instruction tracer's vector commit-log feature.
//
// Ara stores each architectural vector register striped across `NrLanes` lanes,
// and inside a lane across `NrVRFBanksPerLane` (=8) banks of 64-bit words. The
// real VRF is an SRAM whose contents cannot be read out for tracing without
// disturbing the design, so we keep a *mirror*: every bank write that the lane
// drives onto its `vrf_*` interface is replayed here. Reading register `vid`
// returns its full VLEN-bit contents in the *lane-shuffled* (physical) byte
// order; the off-chip / sim formatter de-shuffles it with ara_pkg::shuffle_index
// (so the byte order is correct by construction).
//
// Addressing (from ara_pkg / operand_requester.sv):
//   * `vaddr_t` is a GLOBAL 64-bit-word index inside a lane's VRF.
//   * the bank that holds global word `gw` is  gw[$clog2(NrBanks)-1:0]
//   * the per-bank ("in-bank") word address is gw >> $clog2(NrBanks)
//   * register `vid` starts at global word  vaddr(vid) = vid * WordsPerReg
// The per-bank address driven on `vrf_addr` is therefore the IN-BANK address,
// so the global word of a write at bank b is  gw = (addr << log2(NrBanks)) | b.
// `AddrInBank` lets you flip this if a future Ara revision drives the global
// word directly (set 0 -> gw = addr).

module instr_tracer_synth_vrf_shadow import ara_pkg::*; #(
  parameter int unsigned NrLanes    = 4,
  // 1: per-bank `vrf_addr` is the in-bank word index (current Ara); 0: it is the
  // global word index. Only affects how a write address is mapped to a word.
  parameter bit          AddrInBank = 1'b1,
  // --- derived (do not override) ---
  localparam int unsigned NrBanks      = NrVRFBanksPerLane,                 // 8
  localparam int unsigned WordsPerReg  = VLEN / (64 * NrLanes),             // 64-bit words / reg / lane
  localparam int unsigned WordsPerLane = 32 * WordsPerReg,                  // 32 architectural vregs
  localparam int unsigned GwW          = (WordsPerLane > 1) ? $clog2(WordsPerLane) : 1,
  localparam int unsigned BankSel      = (NrBanks > 1) ? $clog2(NrBanks) : 0
) (
  input  logic                                              clk_i,
  input  logic                                              rst_ni,
  // ---- mirrored lane VRF write ports (one set of NrBanks per lane) ----------
  input  logic [NrLanes-1:0][NrBanks-1:0]                   wen_i,
  input  logic [NrLanes-1:0][NrBanks-1:0][GwW-1:0]          addr_i,   // in-bank word addr (see AddrInBank)
  input  logic [NrLanes-1:0][NrBanks-1:0][63:0]             wdata_i,  // elen_t = 64 bit
  input  logic [NrLanes-1:0][NrBanks-1:0][7:0]              be_i,     // byte enables
  // ---- snapshot read of a whole architectural vector register ---------------
  input  logic [4:0]                                        rd_vid_i,
  output logic [VLEN-1:0]                                   rd_data_o // RAW (lane-shuffled) bytes
);

  // Flat per-lane store, indexed by GLOBAL 64-bit-word index (bank folded in).
  logic [63:0] mem_q [NrLanes][WordsPerLane];

  // ---- write: replay every bank write, byte-granular -----------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned l = 0; l < NrLanes; l++)
        for (int unsigned w = 0; w < WordsPerLane; w++)
          mem_q[l][w] <= '0;            // match Spike's zero-initialised VRF
    end else begin
      for (int unsigned l = 0; l < NrLanes; l++) begin
        for (int unsigned b = 0; b < NrBanks; b++) begin
          if (wen_i[l][b]) begin
            automatic logic [GwW-1:0] gw;
            gw = AddrInBank ? GwW'((addr_i[l][b] << BankSel) | b) : addr_i[l][b];
            for (int unsigned k = 0; k < 8; k++)
              if (be_i[l][b][k]) mem_q[l][gw][k*8 +: 8] <= wdata_i[l][b][k*8 +: 8];
          end
        end
      end
    end
  end

  // ---- read: assemble v[vid] in lane-shuffled (physical) byte order ---------
  // Physical layout (RVV v0.9 striping, SLEN=64): consecutive 8-byte words cycle
  // through the lanes -> lane0.w0, lane1.w0, ..., laneN-1.w0, lane0.w1, ...
  always_comb begin
    rd_data_o = '0;
    for (int unsigned pb = 0; pb < VLENB; pb++) begin
      automatic int unsigned grp = pb >> 3;            // which 8-byte word in the concat layout
      automatic int unsigned lane = grp % NrLanes;
      automatic int unsigned wreg = grp / NrLanes;     // word within the register, per lane
      automatic int unsigned byt  = pb & 3'h7;
      automatic logic [GwW-1:0] gw = GwW'(rd_vid_i * WordsPerReg + wreg);
      rd_data_o[pb*8 +: 8] = mem_q[lane][gw][byt*8 +: 8];
    end
  end

endmodule : instr_tracer_synth_vrf_shadow
