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
  // CSR address -> ABI name (mirrors CVA6 instr_trace_item.svh csrAddrToStr).
  // Returns "" for CSRs not in the table (then only the number is printed).
  // ---------------------------------------------------------------------------
  function automatic string csr_name(logic [11:0] a);
    case (a)
      12'h001: csr_name = "fflags";    12'h002: csr_name = "frm";
      12'h003: csr_name = "fcsr";
      12'h100: csr_name = "sstatus";   12'h104: csr_name = "sie";
      12'h105: csr_name = "stvec";     12'h106: csr_name = "scounteren";
      12'h140: csr_name = "sscratch";  12'h141: csr_name = "sepc";
      12'h142: csr_name = "scause";    12'h143: csr_name = "stval";
      12'h144: csr_name = "sip";       12'h180: csr_name = "satp";
      12'h300: csr_name = "mstatus";   12'h301: csr_name = "misa";
      12'h302: csr_name = "medeleg";   12'h303: csr_name = "mideleg";
      12'h304: csr_name = "mie";       12'h305: csr_name = "mtvec";
      12'h306: csr_name = "mcounteren";12'h340: csr_name = "mscratch";
      12'h341: csr_name = "mepc";      12'h342: csr_name = "mcause";
      12'h343: csr_name = "mtval";     12'h344: csr_name = "mip";
      12'h3a0: csr_name = "pmpcfg0";   12'h3b0: csr_name = "pmpaddr0";
      12'h7a0: csr_name = "tselect";   12'h7a1: csr_name = "tdata1";
      12'h7a2: csr_name = "tdata2";    12'h7a3: csr_name = "tdata3";
      12'h7a4: csr_name = "tinfo";     12'h7b0: csr_name = "dcsr";
      12'h7b1: csr_name = "dpc";       12'h7b2: csr_name = "dscratch0";
      12'h7b3: csr_name = "dscratch1";
      12'hb00: csr_name = "mcycle";    12'hb02: csr_name = "minstret";
      12'hc00: csr_name = "cycle";     12'hc01: csr_name = "time";
      12'hc02: csr_name = "instret";
      12'hf11: csr_name = "mvendorid"; 12'hf12: csr_name = "marchid";
      12'hf13: csr_name = "mimpid";    12'hf14: csr_name = "mhartid";
      default: csr_name = "";
    endcase
  endfunction

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

    // Register number with NO space, even for a single digit (e.g. "x6", "x31").
    rd_s = $sformatf("%s%0d", rf_s, p.rd);

    // Base line: <priv> 0x<pc> (0x<instr>) [<reg> 0x<value>]
    // priv printed with %d (matches riscv::spikeCommitLog on the 2-bit priv).
    if (p.rd_fpr || p.rd != 0)
      s = $sformatf("%d 0x%h %s %s 0x%h", p.priv, pc64, instr_word, rd_s, res64);
    else
      s = $sformatf("%d 0x%h %s", p.priv, pc64, instr_word);

    // Spike-style memory token. STORE prints " mem 0x<addr> 0x<data>" (data at
    // the access width via slicing). LOAD prints only " mem 0x<addr>" -- the
    // loaded value already appears as the rd write, matching Spike's commit log.
    if (p.mem_op == MEM_STORE) begin
      case (p.mem_size)
        2'd0:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[7:0]);
        2'd1:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[15:0]);
        2'd2:    mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[31:0]);
        default: mem_s = $sformatf(" mem 0x%h 0x%h", p.mem_addr, p.mem_data[63:0]);
      endcase
      s = {s, mem_s};
    end else if (p.mem_op == MEM_LOAD) begin
      s = {s, $sformatf(" mem 0x%h", p.mem_addr)};
    end

    // Spike-style CSR write token: " c<addr>_<name> 0x<value>" (addr in decimal;
    // ABI name appended when known, e.g. "c769_misa").
    if (p.csr_we) begin
      string nm = csr_name(p.csr_addr);
      if (nm != "")
        s = {s, $sformatf(" c%0d_%s 0x%h", p.csr_addr, nm, 64'(p.csr_wdata))};
      else
        s = {s, $sformatf(" c%0d 0x%h", p.csr_addr, 64'(p.csr_wdata))};
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
