// ============================================================================
// Ví dụ tích hợp tracer tổng hợp được (SCALAR + VECTOR/RVV) vào ara_system.
// Dán đoạn này vào trong testbench/hệ thống đã có instance `i_dut` = ara_system:
//   - i_dut.i_ariane : lõi CVA6 (commit stage)               -> log lệnh scalar
//   - i_dut.i_ara    : bộ vector Ara (VRF + dispatcher)       -> log lệnh vector
// Module bao quanh cần:  import instr_tracer_synth_pkg::*; import ara_pkg::*;
// Chỉnh `NrLanes` cho khớp cấu hình Ara của bạn.
// ============================================================================
localparam int unsigned NrLanes = 4;

// ---- tín hiệu trace ----
commit_log_beat_t    trace_beat;
logic                trace_valid, trace_ready, trace_overflow;
vec_commit_log_pkt_t vec_beat;
logic                vec_valid, vec_ready, vec_overflow;

// ---------------------------------------------------------------------------
// (1) SYNTHESIZABLE: tracer SCALAR — bắt commit + đóng gói + FIFO → ready/valid
// ---------------------------------------------------------------------------
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
  // CSR write signals -> Spike-style "c<addr> 0x<value>" cho csrrw/csrrs/csrrc
  .csr_commit_i ( i_dut.i_ariane.csr_commit_commit_ex ),
  .csr_op_i     ( i_dut.i_ariane.csr_op_commit_csr    ),
  .csr_waddr_i  ( i_dut.i_ariane.csr_addr_ex_csr      ),
  .csr_operand_i( i_dut.i_ariane.csr_wdata_commit_csr ),
  .csr_old_i    ( i_dut.i_ariane.csr_rdata_csr_commit ),
  // LSU memory-access signals -> Spike-style "mem 0x<addr> 0x<data>" cho load/store
  .st_valid_i ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i     ),
  .st_paddr_i ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i     ),
  .st_data_i  ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_i      ),
  .st_size_i  ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_size_i ),
  .ld_valid_i ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.tag_valid        ),
  .ld_kill_i  ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.kill_req         ),
  .ld_paddr_i ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.paddr_i                     ),
  .ld_size_i  ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.data_size        ),
  .flush_addr_i ( i_dut.i_ariane.flush_ctrl_ex ),
  .trace_valid_o(trace_valid), .trace_beat_o(trace_beat),
  .trace_ready_i(trace_ready),          // ← do sink lái
  .overflow_o(trace_overflow)
);

// ---------------------------------------------------------------------------
// (1b) SYNTHESIZABLE: tracer VECTOR (RVV)  -- xuất dòng Spike:
//        <priv> 0x<pc> (0x<insn>) e<sew> <m|mf><lmul> l<vl> v<vd> 0x<VLEN-hex>
//   Lệnh vector retire ở CVA6 (fu=ACCEL) nhưng dữ liệu vd nằm trong VRF của Ara,
//   trải (shuffle) qua các lane. Ta tap 3 nguồn:
//     - commit  : i_dut.i_ariane.*                         (pc/instr/priv/debug)
//     - vtype/vl: i_dut.i_ara.i_dispatcher.*               (vsew/vlmul/vl)
//     - ghi VRF : i_dut.i_ara.gen_lanes[L].i_lane.vrf_*     (shadow VRF)
//   LƯU Ý: các đường phân cấp và giả định AddrInBank=1 phụ thuộc cấu hình Ara —
//          kiểm chứng bằng mô phỏng trước khi tin (xem VECTOR.md §6).
// ---------------------------------------------------------------------------
localparam int unsigned NrBanks      = ara_pkg::NrVRFBanksPerLane;            // 8
localparam int unsigned WordsPerLane = 32 * (ara_pkg::VLEN / (64 * NrLanes));
localparam int unsigned GwW          = (WordsPerLane > 1) ? $clog2(WordsPerLane) : 1;

// gom cổng ghi VRF của tất cả lane vào mảng packed cho tracer vector
logic [NrLanes-1:0][NrBanks-1:0]          vrf_wen_p;
logic [NrLanes-1:0][NrBanks-1:0][GwW-1:0] vrf_addr_p;   // địa chỉ word trong-bank
logic [NrLanes-1:0][NrBanks-1:0][63:0]    vrf_wdata_p;
logic [NrLanes-1:0][NrBanks-1:0][7:0]     vrf_be_p;

for (genvar L = 0; L < NrLanes; L++) begin : gen_vrf_tap
  assign vrf_wen_p[L] = i_dut.i_ara.gen_lanes[L].i_lane.vrf_wen;
  for (genvar b = 0; b < NrBanks; b++) begin : gen_vrf_tap_bank
    assign vrf_addr_p [L][b] = i_dut.i_ara.gen_lanes[L].i_lane.vrf_addr[b][GwW-1:0];
    assign vrf_wdata_p[L][b] = i_dut.i_ara.gen_lanes[L].i_lane.vrf_wdata[b];
    assign vrf_be_p   [L][b] = i_dut.i_ara.gen_lanes[L].i_lane.vrf_be[b];
  end
end

instr_tracer_synth_vec #(.NrLanes(NrLanes), .FifoDepth(4)) i_vec_tracer (
  .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0), .testmode_i(1'b0),
  .commit_instr_i ( i_dut.i_ariane.commit_instr_id_commit ),
  .commit_ack_i   ( i_dut.i_ariane.commit_ack             ),
  .instr_word_i   ( { i_dut.i_ariane.commit_instr_id_commit[1].ex.tval[31:0],
                      i_dut.i_ariane.commit_instr_id_commit[0].ex.tval[31:0] } ),
  .priv_lvl_i   ( i_dut.i_ariane.priv_lvl   ),
  .debug_mode_i ( i_dut.i_ariane.debug_mode ),
  // vtype/vl hiện hành của Ara (trong dispatcher)
  .vsew_i  ( i_dut.i_ara.i_dispatcher.vtype_q.vsew  ),
  .vlmul_i ( i_dut.i_ara.i_dispatcher.vtype_q.vlmul ),
  .vl_i    ( i_dut.i_ara.i_dispatcher.vl_q          ),
  // cổng ghi VRF mọi lane -> shadow VRF bên trong tracer
  .vrf_wen_i (vrf_wen_p),  .vrf_addr_i(vrf_addr_p),
  .vrf_wdata_i(vrf_wdata_p), .vrf_be_i(vrf_be_p),
  .vec_trace_valid_o(vec_valid), .vec_trace_beat_o(vec_beat),
  .vec_trace_ready_i(vec_ready),        // ← do sink lái
  .overflow_o(vec_overflow)
);

// ---------------------------------------------------------------------------
// (2) SIM-ONLY: sink — rút CẢ beat scalar lẫn record vector, IN 1 file log
//     (trace_hart_0_commit.synth.log) đúng định dạng Spike, theo thứ tự chương trình.
// ---------------------------------------------------------------------------
instr_tracer_synth_sink #(.HartId(64'h0), .NrLanes(NrLanes), .EmitPktHex(1'b0)) i_sink (
  .clk_i(clk), .rst_ni(rst_n),
  .trace_valid_i(trace_valid),
  .trace_beat_i (trace_beat),
  .trace_ready_o(trace_ready),          // → luôn 1 (sim)
  .overflow_i   (trace_overflow),
  // cổng vector
  .vec_trace_valid_i(vec_valid),
  .vec_trace_beat_i (vec_beat),
  .vec_trace_ready_o(vec_ready),        // → bật khi luồng scalar rút 1 lệnh vector
  .vec_overflow_i   (vec_overflow)
);
