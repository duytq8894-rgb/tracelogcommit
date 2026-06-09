// ============================================================================
// Ví dụ HOÀN CHỈNH (self-contained): KHỞI TẠO DUT + tracer tổng hợp được.
//
//   (0)  Khởi tạo DUT: ara_system (lõi CVA6 + Ara) làm `i_dut`, sinh clk/reset,
//        nối 1 cổng AXI master tới bộ nhớ (axi_to_mem + mảng), nạp program.hex.
//   (1)  Tracer SCALAR  (instr_tracer_synth)        -> log lệnh vô hướng.
//   (1b) Tracer VECTOR  (instr_tracer_synth_vec)    -> log lệnh vector (RVV).
//   (2)  Sink (sim-only) -> in 1 file trace_hart_0_commit.synth.log (định dạng Spike).
//
// Đây là bản gọn, độc lập của hardware/tb/tb_ara_system_trace.sv: phần (0) chính là
// "init DUT". Ba khối (1),(1b),(2) có thể COPY nguyên sang testbench khác đã có sẵn
// instance `i_dut` = ara_system (chỉ cần khai báo clk/rst_n + import 2 package).
//
// Biên dịch cùng RTL của Ara; chỉnh NrLanes / MemFile cho khớp cấu hình của bạn.
// ============================================================================
`include "axi/typedef.svh"
`include "axi/assign.svh"

module example_init_dut import ara_pkg::*; import instr_tracer_synth_pkg::*; #(
  parameter int unsigned NrLanes = 4,
  parameter string       MemFile = "program.hex"   // ảnh $readmemh (word rộng AxiWideDataWidth)
);

  // ==========================================================================
  // (0a) Tham số & kiểu AXI  (sao theo ara_soc.sv để ara_system elaborate giống hệt)
  // ==========================================================================
  localparam int unsigned AxiAddrWidth       = 64;
  localparam int unsigned AxiUserWidth       = 1;
  localparam int unsigned AxiNarrowDataWidth = 64;                 // Ariane (narrow)
  localparam int unsigned AxiWideDataWidth   = 32 * NrLanes;       // Ara   (wide) = AxiDataWidth
  localparam int unsigned AxiIdWidth         = 5;                  // SoC-level id width
  localparam int unsigned NrAXIMasters       = 1;
  localparam int unsigned AxiSocIdWidth      = AxiIdWidth - $clog2(NrAXIMasters); // 5
  localparam int unsigned AxiCoreIdWidth     = AxiSocIdWidth - 1;                 // 4
  localparam logic [63:0] DRAMBase           = 64'h8000_0000;

  typedef logic [AxiAddrWidth-1:0]          axi_addr_t;
  typedef logic [AxiWideDataWidth-1:0]      axi_data_t;
  typedef logic [AxiWideDataWidth/8-1:0]    axi_strb_t;
  typedef logic [AxiUserWidth-1:0]          axi_user_t;
  typedef logic [AxiIdWidth-1:0]            axi_id_t;
  typedef logic [AxiNarrowDataWidth-1:0]    axi_narrow_data_t;
  typedef logic [AxiNarrowDataWidth/8-1:0]  axi_narrow_strb_t;
  typedef logic [AxiCoreIdWidth-1:0]        axi_core_id_t;

  // Sinh <name>_req_t/_resp_t và <name>_{aw,w,b,ar,r}_chan_t.
  `AXI_TYPEDEF_ALL(system,     axi_addr_t, axi_id_t,      axi_data_t,        axi_strb_t,        axi_user_t)
  `AXI_TYPEDEF_ALL(ara_axi,    axi_addr_t, axi_core_id_t, axi_data_t,        axi_strb_t,        axi_user_t)
  `AXI_TYPEDEF_ALL(ariane_axi, axi_addr_t, axi_core_id_t, axi_narrow_data_t, axi_narrow_strb_t, axi_user_t)

  // ==========================================================================
  // (0b) Clock & reset
  // ==========================================================================
  logic clk, rst_n;
  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;              // 100 MHz
  end
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ==========================================================================
  // (0c) DUT: ara_system  (1 cổng AXI master: axi_req_o / axi_resp_i)  ->  i_dut
  // ==========================================================================
  system_req_t  axi_req;
  system_resp_t axi_resp;

  ara_system #(
    .NrLanes           ( NrLanes              ),
    .AxiAddrWidth      ( AxiAddrWidth         ),
    .AxiIdWidth        ( AxiCoreIdWidth       ),   // CORE id; mux mở rộng lên system id
    .AxiNarrowDataWidth( AxiNarrowDataWidth   ),
    .AxiWideDataWidth  ( AxiWideDataWidth     ),
    .ara_axi_ar_t      ( ara_axi_ar_chan_t    ),
    .ara_axi_aw_t      ( ara_axi_aw_chan_t    ),
    .ara_axi_b_t       ( ara_axi_b_chan_t     ),
    .ara_axi_r_t       ( ara_axi_r_chan_t     ),
    .ara_axi_w_t       ( ara_axi_w_chan_t     ),
    .ara_axi_req_t     ( ara_axi_req_t        ),
    .ara_axi_resp_t    ( ara_axi_resp_t       ),
    .ariane_axi_ar_t   ( ariane_axi_ar_chan_t ),
    .ariane_axi_aw_t   ( ariane_axi_aw_chan_t ),
    .ariane_axi_b_t    ( ariane_axi_b_chan_t  ),
    .ariane_axi_r_t    ( ariane_axi_r_chan_t  ),
    .ariane_axi_w_t    ( ariane_axi_w_chan_t  ),
    .ariane_axi_req_t  ( ariane_axi_req_t     ),
    .ariane_axi_resp_t ( ariane_axi_resp_t    ),
    .system_axi_ar_t   ( system_ar_chan_t     ),
    .system_axi_aw_t   ( system_aw_chan_t     ),
    .system_axi_b_t    ( system_b_chan_t      ),
    .system_axi_r_t    ( system_r_chan_t      ),
    .system_axi_w_t    ( system_w_chan_t      ),
    .system_axi_req_t  ( system_req_t         ),
    .system_axi_resp_t ( system_resp_t        )
  ) i_dut (
    .clk_i        ( clk       ),
    .rst_ni       ( rst_n     ),
    .boot_addr_i  ( DRAMBase  ),   // bắt đầu fetch từ DRAM base
    .hart_id_i    ( 3'd0      ),
    .scan_enable_i( 1'b0      ),
    .scan_data_i  ( 1'b0      ),
    .scan_data_o  ( /* open */),
    .axi_req_o    ( axi_req   ),
    .axi_resp_i   ( axi_resp  )
  );

  // ==========================================================================
  // (0d) Bộ nhớ: cầu AXI -> mem + mảng word hành vi (cùng đường như ara_soc)
  // ==========================================================================
  logic        l2_req, l2_we, l2_rvalid;
  axi_addr_t   l2_addr;
  axi_data_t   l2_wdata, l2_rdata;
  axi_strb_t   l2_be;

  axi_to_mem #(
    .axi_req_t ( system_req_t     ),
    .axi_resp_t( system_resp_t    ),
    .AddrWidth ( AxiAddrWidth     ),
    .DataWidth ( AxiWideDataWidth ),
    .IdWidth   ( AxiSocIdWidth    ),
    .NumBanks  ( 1                )
  ) i_axi_to_mem (
    .clk_i       ( clk      ),
    .rst_ni      ( rst_n    ),
    .busy_o      ( /* open */ ),
    .axi_req_i   ( axi_req  ),
    .axi_resp_o  ( axi_resp ),
    .mem_req_o   ( l2_req   ),
    .mem_gnt_i   ( l2_req   ),   // 1 chu kỳ, luôn grant
    .mem_addr_o  ( l2_addr  ),
    .mem_wdata_o ( l2_wdata ),
    .mem_strb_o  ( l2_be    ),
    .mem_atop_o  ( /* open */ ),
    .mem_we_o    ( l2_we    ),
    .mem_rvalid_i( l2_rvalid),
    .mem_rdata_i ( l2_rdata )
  );

  localparam int unsigned MemWords = 1 << 18;            // 256k word rộng
  logic [AxiWideDataWidth-1:0] mem [0:MemWords-1];
  // địa chỉ byte -> chỉ số word rộng, tính từ DRAM base
  wire [AxiAddrWidth-1:0] word_idx = (l2_addr - DRAMBase) >> $clog2(AxiWideDataWidth/8);

  always_ff @(posedge clk) begin
    if (l2_req && l2_we) begin
      for (int b = 0; b < AxiWideDataWidth/8; b++)
        if (l2_be[b]) mem[word_idx][8*b +: 8] <= l2_wdata[8*b +: 8];
    end
    l2_rdata  <= mem[word_idx];
    l2_rvalid <= l2_req;           // 1 chu kỳ trễ đọc
  end

  initial begin
    // Nạp chương trình (ảnh hex các word rộng AxiWideDataWidth, addr 0 == DRAMBase).
    // Tạo ví dụ: riscv64-...-objcopy -O verilog prog.elf prog.hex  (chỉnh độ rộng).
    $readmemh(MemFile, mem);
  end

  // ==========================================================================
  // tín hiệu trace (dùng chung cho (1),(1b),(2))
  // ==========================================================================
  commit_log_beat_t    trace_beat;
  logic                trace_valid, trace_ready, trace_overflow;
  vec_commit_log_pkt_t vec_beat;
  logic                vec_valid, vec_ready, vec_overflow;

  // ==========================================================================
  // (1) SYNTHESIZABLE: tracer SCALAR — bắt commit + đóng gói + FIFO → ready/valid
  //     (COPY nguyên khối này sang TB khác đã có i_dut/clk/rst_n nếu cần)
  // ==========================================================================
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

  // ==========================================================================
  // (1b) SYNTHESIZABLE: tracer VECTOR (RVV)  -- xuất dòng Spike (theo trace_vector.md):
  //        <priv> 0x<pc> (0x<insn>) v<vd> 0x<VLEN-hex> [c1_fflags 0x<val>]
  //   (KHÔNG in tóm tắt e<sew> <m|mf><lmul> l<vl> — bản Spike đích chỉ in token v<vd>;
  //    mask de-shuffle ở EW8 (§3.13); op FP kèm token c1_fflags (§3.14). Xem VECTOR.md.)
  //   Lệnh vector retire ở CVA6 (fu=ACCEL) nhưng dữ liệu vd nằm trong VRF của Ara,
  //   trải (shuffle) qua các lane. Ta tap: commit (i_dut.i_ariane.*), vtype/vl + fflags
  //   (i_dut.i_ara.i_dispatcher.*), và cổng ghi VRF (i_dut.i_ara.gen_lanes[L].i_lane.*).
  //   LƯU Ý: đường phân cấp & giả định AddrInBank=1 phụ thuộc cấu hình Ara — kiểm
  //          chứng bằng mô phỏng (xem VECTOR.md §6).
  // ==========================================================================
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
    // fflags vector (§3.14): bus per-lane vào dispatcher -> token c1_fflags
    .fflags_i       ( i_dut.i_ara.i_dispatcher.fflags_ex_i       ),
    .fflags_valid_i ( i_dut.i_ara.i_dispatcher.fflags_ex_valid_i ),
    // cổng ghi VRF mọi lane -> shadow VRF bên trong tracer
    .vrf_wen_i (vrf_wen_p),  .vrf_addr_i(vrf_addr_p),
    .vrf_wdata_i(vrf_wdata_p), .vrf_be_i(vrf_be_p),
    .vec_trace_valid_o(vec_valid), .vec_trace_beat_o(vec_beat),
    .vec_trace_ready_i(vec_ready),        // ← do sink lái
    .overflow_o(vec_overflow)
  );

  // ==========================================================================
  // (2) SIM-ONLY: sink — rút CẢ beat scalar lẫn record vector, IN 1 file log
  //     (trace_hart_0_commit.synth.log) đúng định dạng Spike, theo thứ tự chương trình.
  // ==========================================================================
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

  // ==========================================================================
  // (3) Điều khiển chạy mô phỏng
  // ==========================================================================
  initial begin
    @(posedge rst_n);
    repeat (100_000) @(posedge clk);
    $display("[example_init_dut] xong. Log: trace_hart_0_commit.synth.log");
    $finish;
  end

endmodule : example_init_dut
