commit_log_beat_t trace_beat;
logic             trace_valid, trace_ready, trace_overflow;

// (1) SYNTHESIZABLE: bắt commit + đóng gói + FIFO → cổng ready/valid
instr_tracer_synth #(.FifoDepth(32)) i_tracer (
  .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0), .testmode_i(1'b0),
  .commit_instr_i ( i_dut.i_ariane.commit_instr_id_commit ),
  .commit_ack_i   ( i_dut.i_ariane.commit_ack             ),
  .instr_word_i   ( { i_dut.i_ariane.commit_instr_id_commit[1].ex.tval[31:0],
                      i_dut.i_ariane.commit_instr_id_commit[0].ex.tval[31:0] } ),
  .waddr_i (i_dut.i_ariane.waddr_commit_id), .wdata_i (i_dut.i_ariane.wdata_commit_id),
  .we_gpr_i(i_dut.i_ariane.we_gpr_commit_id), .we_fpr_i(i_dut.i_ariane.we_fpr_commit_id),
  .priv_lvl_i(i_dut.i_ariane.priv_lvl), .debug_mode_i(i_dut.i_ariane.debug_mode),
  .exception_i(i_dut.i_ariane.commit_stage_i.exception_o),
  .trace_valid_o(trace_valid), .trace_beat_o(trace_beat),
  .trace_ready_i(trace_ready),          // ← do sink lái
  .overflow_o(trace_overflow)
);

// (2) SIM-ONLY: rút beat + IN file log bằng SystemVerilog
instr_tracer_synth_sink #(.HartId(64'h0), .EmitPktHex(1'b0)) i_sink (
  .clk_i(clk), .rst_ni(rst_n),
  .trace_valid_i(trace_valid),
  .trace_beat_i (trace_beat),
  .trace_ready_o(trace_ready),          // → luôn 1 (sim)
  .overflow_i   (trace_overflow)
);
