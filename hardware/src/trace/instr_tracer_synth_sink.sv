// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Simulation-only sink for the synthesizable instruction tracer.
//
// This module is NOT part of the design. It models whatever consumes the
// streaming trace port in a real system (a UART, a debug probe, a DMA, ...).
//
// In simulation it drains the trace port and *prints the Spike commit log
// directly in SystemVerilog* (a $fwrite of a formatted string), exactly like
// CVA6's original instr_tracer does with riscv::spikeCommitLog(). The output
// file `trace_hart_<id>_commit.log` is byte-for-byte the same format as the
// original tracer's commit log, so no off-chip Python decoder is needed for the
// simulation flow.
//
// (For a real-silicon binary stream you would still pack the records and decode
//  them off-chip; set EmitPktHex=1 to additionally dump the raw hex packets.)
//
// Everything here is wrapped so it is excluded from synthesis.

`ifndef SYNTHESIS
// pragma translate_off
module instr_tracer_synth_sink import instr_tracer_synth_pkg::*; #(
  parameter logic [63:0] HartId     = 64'h0,
  // Set to 1 to also dump the raw packed records as hex (trace_hart_<id>.pkt.hex),
  // e.g. to exercise the off-chip scripts/spike_trace_decode.py flow.
  parameter bit          EmitPktHex = 1'b0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             trace_valid_i,
  input  commit_log_beat_t trace_beat_i,
  output logic             trace_ready_o,
  input  logic             overflow_i
);

  int unsigned f_log, f_hex;
  string       fn_log, fn_hex;

  // Always ready to drain the trace in simulation.
  assign trace_ready_o = 1'b1;

  // ---------------------------------------------------------------------------
  // Format one retired-instruction record into a Spike commit-log line.
  // Reproduces riscv::spikeCommitLog() (riscv_pkg.sv) field-for-field, so the
  // output matches the original tracer's trace_hart_<id>_commit.log exactly.
  // ---------------------------------------------------------------------------
  function automatic string spike_commit_str(commit_log_pkt_t p);
    string       s, instr_word, rd_s, rf_s, mem_s;
    logic [63:0] pc64, res64;
    // spikeCommitLog() takes pc/result as logic[63:0] -> always 16 hex digits,
    // independent of XLEN. Zero-extend a 32-bit core's values.
    pc64  = 64'(p.pc);
    res64 = 64'(p.wdata);
    rf_s  = p.rd_fpr ? "f" : "x";

    // 16-bit (RVC) vs 32-bit instruction word (keyed off instr[1:0] != 2'b11).
    if (p.instr[1:0] != 2'b11) instr_word = $sformatf("(0x%h)", p.instr[15:0]);
    else                       instr_word = $sformatf("(0x%h)", p.instr);

    // Note the (intentional) space for single-digit register numbers ("x 8").
    if (p.rd < 10) rd_s = $sformatf("%s %0d", rf_s, p.rd);
    else           rd_s = $sformatf("%s%0d", rf_s, p.rd);

    // Base line: <priv> 0x<pc> (0x<instr>) [<reg> 0x<value>]
    // priv printed with %d (matches riscv::spikeCommitLog on the 2-bit priv).
    if (p.rd_fpr || p.rd != 0)
      s = $sformatf("%d 0x%h %s %s 0x%h", p.priv, pc64, instr_word, rd_s, res64);
    else
      s = $sformatf("%d 0x%h %s", p.priv, pc64, instr_word);

    // Spike-style memory token for loads/stores: " mem 0x<addr> 0x<data>".
    // The data is printed at the access width (2/4/8/16 hex digits) by slicing
    // (%h zero-pads to the operand bit-width; SV has no dynamic-width spec).
    if (p.mem_op != MEM_NONE) begin
      case (p.mem_size)
        2'd0:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[7:0]);
        2'd1:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[15:0]);
        2'd2:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[31:0]);
        default: mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[63:0]);
      endcase
      s = {s, mem_s};
    end
    return s;
  endfunction

  initial begin
    // Distinct name so it does NOT clobber the original tracer's
    // trace_hart_<id>_commit.log under QuestaSim (both run there); diff the two.
    $sformat(fn_log, "trace_hart_%0d_commit.synth.log", HartId);
    f_log = $fopen(fn_log, "w");
    if (f_log == 0) $fatal(1, "[TRACE-SINK] cannot open %s", fn_log);
    $display("[TRACE-SINK] writing Spike commit log to %s", fn_log);
    if (EmitPktHex) begin
      $sformat(fn_hex, "trace_hart_%0d.pkt.hex", HartId);
      f_hex = $fopen(fn_hex, "w");
      if (f_hex == 0) $fatal(1, "[TRACE-SINK] cannot open %s", fn_hex);
    end
  end

  // Drain one beat per accepted handshake; emit port 0 before port 1 so the
  // file is in program order.
  always_ff @(posedge clk_i) begin
    if (rst_ni && trace_valid_i && trace_ready_o) begin
      for (int unsigned p = 0; p < NrCommitPorts; p++) begin
        if (trace_beat_i.valid[p]) begin
          // The original tracer writes a commit-log line for every retired
          // instruction, gated only by !debug_mode (instr_tracer.sv:116,195) --
          // NOT by exceptions. Key on `retired` (= commit_ack), never on ex_valid.
          if (trace_beat_i.pkt[p].retired && !trace_beat_i.pkt[p].debug) begin
            $fwrite(f_log, "%s\n", spike_commit_str(trace_beat_i.pkt[p]));
          end
          if (EmitPktHex) $fwrite(f_hex, "%0h\n", trace_beat_i.pkt[p]);
        end
      end
    end
    if (rst_ni && overflow_i) begin
      $warning("[TRACE-SINK] trace FIFO overflow: a commit beat was dropped");
    end
  end

  final begin
    if (f_log) $fclose(f_log);
    if (EmitPktHex && f_hex) $fclose(f_hex);
  end

endmodule : instr_tracer_synth_sink
// pragma translate_on
`endif
