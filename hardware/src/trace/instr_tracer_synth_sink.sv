// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Simulation-only sink for the synthesizable instruction tracer.
//
// This module is NOT part of the design. It models whatever consumes the
// streaming trace port in a real system (a UART, a debug probe, a DMA, ...).
// In simulation it simply asserts `trace_ready_i` and writes every captured
// `commit_log_pkt_t` as one hex line to a file. That hex file is then turned
// into a Spike-format commit log off-chip by `scripts/spike_trace_decode.py`.
//
// Everything here is wrapped so it is excluded from synthesis.

`ifndef SYNTHESIS
// pragma translate_off
module instr_tracer_synth_sink import instr_tracer_synth_pkg::*; #(
  parameter logic [63:0] HartId = 64'h0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             trace_valid_i,
  input  commit_log_beat_t trace_beat_i,
  output logic             trace_ready_o,
  input  logic             overflow_i
);

  int unsigned f;
  string       fn;

  // Always ready to drain the trace in simulation.
  assign trace_ready_o = 1'b1;

  initial begin
    $sformat(fn, "trace_hart_%02d.pkt.hex", HartId);
    f = $fopen(fn, "w");
    if (f == 0) $fatal(1, "[TRACE-SINK] cannot open %s", fn);
    $display("[TRACE-SINK] writing packed trace records to %s", fn);
  end

  // Drain one beat per accepted handshake; emit port 0 before port 1 so the
  // file is in program order. Each line is the raw hex of one commit_log_pkt_t.
  always_ff @(posedge clk_i) begin
    if (rst_ni && trace_valid_i && trace_ready_o) begin
      for (int unsigned p = 0; p < NrCommitPorts; p++) begin
        if (trace_beat_i.valid[p]) begin
          $fwrite(f, "%0h\n", trace_beat_i.pkt[p]);
        end
      end
    end
    if (rst_ni && overflow_i) begin
      $warning("[TRACE-SINK] trace FIFO overflow: a commit beat was dropped");
    end
  end

  final begin
    if (f) $fclose(f);
  end

endmodule : instr_tracer_synth_sink
// pragma translate_on
`endif
