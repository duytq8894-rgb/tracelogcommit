// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Small synthesizable address-tracking FIFO for the instruction
// tracer. It mirrors the dynamic store_mapping/load_mapping queues of the
// simulation tracer, but as bounded hardware: the LSU pushes one memory
// address (+ data/size) per cycle as it is generated, and the commit stage pops
// it when the matching load/store retires. Because up to two LOADs can retire
// in the same cycle (CVA6 commit port 1 accepts LOAD), it supports popping 0..2
// of the oldest entries per cycle and exposes the two oldest entries.
//
// `flush_i` clears the queue, matching the simulation tracer's flush() which
// drops all pending address mappings on a pipeline flush.
//
// Depth MUST be a power of two (natural pointer wrap-around).

module instr_tracer_addr_fifo #(
  parameter type         dtype = logic,
  // Address width of the queue; depth is 2**AW *by construction* so the
  // power-of-two precondition (needed for the natural pointer wrap) can never
  // be violated by a caller.
  parameter int unsigned AW = 4
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       flush_i,
  // push side (LSU address generation), at most one per cycle
  input  logic       push_i,
  input  dtype       data_i,
  // pop side (commit), 0..2 oldest entries consumed per cycle
  input  logic [1:0] pop_i,
  output dtype       data0_o,   // oldest entry      (valid when avail_o >= 1)
  output dtype       data1_o,   // second-oldest     (valid when avail_o >= 2)
  output logic [1:0] avail_o,   // min(occupancy, 2): how many of data0/1 are valid
  output logic       overflow_o,// a push was dropped because the FIFO was full
  output logic       underflow_o// a pop requested more than was available
);

  localparam int unsigned Depth = 1 << AW;

  dtype          mem_q [Depth];
  logic [AW-1:0] head_q, tail_q;
  logic [AW:0]   cnt_q;

  // Clamp the requested pop to the real occupancy so head_q/cnt_q can never
  // diverge (cnt_q is unsigned; an over-pop would wrap to a huge value and
  // permanently misalign the queue). pop_i is at most 2.
  logic [1:0] pop_eff;
  logic       do_push;
  assign pop_eff = (pop_i > cnt_q) ? cnt_q[1:0] : pop_i;
  // Accept the push if a slot is (or becomes, via a concurrent pop) free.
  assign do_push = push_i && ((cnt_q - pop_eff) != Depth[AW:0]);

  // Qualified reads: return a defined 0 (clearly wrong) rather than stale data
  // if a consumer ever reads beyond the available entries.
  assign data0_o    = (cnt_q >= 1) ? mem_q[head_q]          : '0;
  assign data1_o    = (cnt_q >= 2) ? mem_q[head_q + 1'b1]   : '0;  // natural wrap (Depth = 2**AW)
  assign avail_o    = (cnt_q >= 2) ? 2'd2 : cnt_q[1:0];
  assign overflow_o = push_i && ((cnt_q - pop_eff) == Depth[AW:0]);
  assign underflow_o = (pop_i > cnt_q);                // requested more than held

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      cnt_q  <= '0;
    end else if (flush_i) begin
      head_q <= '0;
      tail_q <= '0;
      cnt_q  <= '0;
    end else begin
      if (do_push) begin
        mem_q[tail_q] <= data_i;
        tail_q        <= tail_q + 1'b1;
      end
      head_q <= head_q + pop_eff;                       // advance by entries consumed
      cnt_q  <= cnt_q + (do_push ? 1 : 0) - pop_eff;    // in [0, Depth]
    end
  end

endmodule : instr_tracer_addr_fifo
