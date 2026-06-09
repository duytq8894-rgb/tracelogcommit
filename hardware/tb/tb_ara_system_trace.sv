// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Minimal example testbench that
//   (1) instantiates `ara_system` (CVA6 core + Ara vector unit),
//   (2) connects its single AXI master port to a memory (axi_to_mem + array),
//   (3) instantiates the *synthesizable* `instr_tracer_synth`, wiring its inputs
//       to the CVA6 commit-stage signals inside ara_system via hierarchical
//       references.
//
// This is a simulation testbench (clock gen, $readmemh, hierarchical refs are
// sim-only); only `instr_tracer_synth` itself is synthesizable.

`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_ara_system_trace import ara_pkg::*; import instr_tracer_synth_pkg::*; #(
  parameter int unsigned NrLanes  = 4,
  parameter string       MemFile  = "program.hex"   // $readmemh image (wide words)
);

  // ---------------------------------------------------------------------------
  // Parameters / AXI types (mirror ara_soc.sv so ara_system elaborates the same)
  // ---------------------------------------------------------------------------
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

  // Generates <name>_req_t/_resp_t and <name>_{aw,w,b,ar,r}_chan_t.
  `AXI_TYPEDEF_ALL(system,     axi_addr_t, axi_id_t,      axi_data_t,        axi_strb_t,        axi_user_t)
  `AXI_TYPEDEF_ALL(ara_axi,    axi_addr_t, axi_core_id_t, axi_data_t,        axi_strb_t,        axi_user_t)
  `AXI_TYPEDEF_ALL(ariane_axi, axi_addr_t, axi_core_id_t, axi_narrow_data_t, axi_narrow_strb_t, axi_user_t)

  // ---------------------------------------------------------------------------
  // Clock and reset
  // ---------------------------------------------------------------------------
  logic clk, rst_n;
  initial begin
    clk = 1'b0;
    forever #5ns clk = ~clk;            // 100 MHz
  end
  initial begin
    rst_n = 1'b0;
    repeat (10) @(posedge clk);
    rst_n = 1'b1;
  end

  // ---------------------------------------------------------------------------
  // DUT: ara_system  (single AXI master port axi_req_o / axi_resp_i)
  // ---------------------------------------------------------------------------
  system_req_t  axi_req;
  system_resp_t axi_resp;

  ara_system #(
    .NrLanes           ( NrLanes              ),
    .AxiAddrWidth      ( AxiAddrWidth         ),
    .AxiIdWidth        ( AxiCoreIdWidth       ),   // CORE id; mux widens to system id
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
    .boot_addr_i  ( DRAMBase  ),   // start fetching from DRAM base
    .hart_id_i    ( 3'd0      ),
    .scan_enable_i( 1'b0      ),
    .scan_data_i  ( 1'b0      ),
    .scan_data_o  ( /* open */),
    .axi_req_o    ( axi_req   ),
    .axi_resp_i   ( axi_resp  )
  );

  // ---------------------------------------------------------------------------
  // Memory: AXI -> mem bridge + a behavioural word array (same path as ara_soc)
  // ---------------------------------------------------------------------------
  logic        l2_req, l2_we, l2_rvalid;
  axi_addr_t   l2_addr;
  axi_data_t   l2_wdata, l2_rdata;
  axi_strb_t   l2_be;

  axi_to_mem #(
    .axi_req_t ( system_req_t   ),
    .axi_resp_t( system_resp_t  ),
    .AddrWidth ( AxiAddrWidth   ),
    .DataWidth ( AxiWideDataWidth ),
    .IdWidth   ( AxiSocIdWidth  ),
    .NumBanks  ( 1              )
  ) i_axi_to_mem (
    .clk_i       ( clk      ),
    .rst_ni      ( rst_n    ),
    .busy_o      ( /* open */ ),
    .axi_req_i   ( axi_req  ),
    .axi_resp_o  ( axi_resp ),
    .mem_req_o   ( l2_req   ),
    .mem_gnt_i   ( l2_req   ),   // single-cycle, always grant
    .mem_addr_o  ( l2_addr  ),
    .mem_wdata_o ( l2_wdata ),
    .mem_strb_o  ( l2_be    ),
    .mem_atop_o  ( /* open */ ),
    .mem_we_o    ( l2_we    ),
    .mem_rvalid_i( l2_rvalid),
    .mem_rdata_i ( l2_rdata )
  );

  localparam int unsigned MemWords = 1 << 18;             // 256k wide words
  logic [AxiWideDataWidth-1:0] mem [0:MemWords-1];
  // byte-address -> wide-word index, relative to DRAM base
  wire [AxiAddrWidth-1:0] word_idx = (l2_addr - DRAMBase) >> $clog2(AxiWideDataWidth/8);

  always_ff @(posedge clk) begin
    if (l2_req && l2_we) begin
      for (int b = 0; b < AxiWideDataWidth/8; b++)
        if (l2_be[b]) mem[word_idx][8*b +: 8] <= l2_wdata[8*b +: 8];
    end
    l2_rdata  <= mem[word_idx];
    l2_rvalid <= l2_req;            // one-cycle read latency
  end

  initial begin
    // Preload the program (hex image of AxiWideDataWidth-wide words, addr 0 == DRAMBase).
    // Generate e.g. with: riscv64-...-objcopy -O verilog prog.elf prog.hex  (adapt width).
    $readmemh(MemFile, mem);
  end

  // ---------------------------------------------------------------------------
  // (1) The SYNTHESIZABLE tracer, wired to the CVA6 commit-stage signals inside
  //     ara_system via hierarchical references (i_dut.i_ariane.*). These are the
  //     same nets the original simulation tracer observes (see ariane.sv).
  // (2) The sim-only sink that CONSUMES the trace port and CREATES the log file
  //     trace_hart_0_commit.synth.log (Spike commit-log format, printed in SV).
  // The two are connected by the ready/valid handshake below.
  // ---------------------------------------------------------------------------
  commit_log_beat_t trace_beat;
  logic             trace_valid, trace_ready, trace_overflow;

  // (1) capture + pack (synthesizable)
  instr_tracer_synth #(
    .FifoDepth ( 32 )
  ) i_tracer (
    .clk_i          ( clk   ),
    .rst_ni         ( rst_n ),
    .flush_i        ( 1'b0  ),
    .testmode_i     ( 1'b0  ),
    .commit_instr_i ( i_dut.i_ariane.commit_instr_id_commit ),
    .commit_ack_i   ( i_dut.i_ariane.commit_ack             ),
    // CVA6 stashes the instruction word in ex.tval when no exception is pending;
    // {port1, port0} packs the two commit ports into [NR_COMMIT_PORTS-1:0][31:0].
    .instr_word_i   ( { i_dut.i_ariane.commit_instr_id_commit[1].ex.tval[31:0],
                        i_dut.i_ariane.commit_instr_id_commit[0].ex.tval[31:0] } ),
    .waddr_i        ( i_dut.i_ariane.waddr_commit_id   ),
    .wdata_i        ( i_dut.i_ariane.wdata_commit_id   ),
    .we_gpr_i       ( i_dut.i_ariane.we_gpr_commit_id  ),
    .we_fpr_i       ( i_dut.i_ariane.we_fpr_commit_id  ),
    .priv_lvl_i     ( i_dut.i_ariane.priv_lvl          ),
    .debug_mode_i   ( i_dut.i_ariane.debug_mode        ),
    .exception_i    ( i_dut.i_ariane.commit_stage_i.exception_o ),
    // CSR write signals -> Spike-style "c<addr> 0x<value>"
    .csr_commit_i   ( i_dut.i_ariane.csr_commit_commit_ex ),
    .csr_op_i       ( i_dut.i_ariane.csr_op_commit_csr    ),
    .csr_waddr_i    ( i_dut.i_ariane.csr_addr_ex_csr      ),
    .csr_operand_i  ( i_dut.i_ariane.csr_wdata_commit_csr ),
    .csr_old_i      ( i_dut.i_ariane.csr_rdata_csr_commit ),
    // LSU memory-access signals -> Spike-style "mem 0x<addr> 0x<data>"
    .st_valid_i     ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i     ),
    .st_paddr_i     ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i     ),
    .st_data_i      ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_i      ),
    .st_size_i      ( i_dut.i_ariane.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_size_i ),
    .ld_valid_i     ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.tag_valid        ),
    .ld_kill_i      ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.kill_req         ),
    .ld_paddr_i     ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.paddr_i                     ),
    .ld_size_i      ( i_dut.i_ariane.ex_stage_i.lsu_i.i_load_unit.req_port_o.data_size        ),
    .flush_addr_i   ( i_dut.i_ariane.flush_ctrl_ex ),
    .trace_valid_o  ( trace_valid    ),
    .trace_beat_o   ( trace_beat     ),
    .trace_ready_i  ( trace_ready    ),   // driven by the sink below
    .overflow_o     ( trace_overflow )
  );

  // ---------------------------------------------------------------------------
  // (1b) The VECTOR (RVV) tracer. Vector instructions retire in CVA6 (fu=ACCEL)
  //      but their destination data lives in Ara's VRF, striped across the lanes.
  //      We tap, via hierarchical references: the CVA6 commit signals (i_ariane.*),
  //      Ara's current vsew/vlmul/vl (i_ara.i_dispatcher.*), and every lane's VRF
  //      write port (i_ara.gen_lanes[L].i_lane.vrf_*). NOTE: the hierarchical
  //      paths and the in-bank-address assumption (AddrInBank=1) are config-
  //      dependent -- validate against your Ara build (see VECTOR.md).
  // ---------------------------------------------------------------------------
  localparam int unsigned NrBanks      = ara_pkg::NrVRFBanksPerLane;            // 8
  localparam int unsigned WordsPerLane = 32 * (ara_pkg::VLEN / (64 * NrLanes));
  localparam int unsigned GwW          = (WordsPerLane > 1) ? $clog2(WordsPerLane) : 1;

  logic [NrLanes-1:0][NrBanks-1:0]          vrf_wen_p;
  logic [NrLanes-1:0][NrBanks-1:0][GwW-1:0] vrf_addr_p;   // in-bank word index
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

  // Ara's current vtype / vl (held in the dispatcher).
  logic [2:0]            vsew_p, vlmul_p;
  logic [VlW-1:0]        vl_p;
  assign vsew_p  = i_dut.i_ara.i_dispatcher.vtype_q.vsew;
  assign vlmul_p = i_dut.i_ara.i_dispatcher.vtype_q.vlmul;
  assign vl_p    = i_dut.i_ara.i_dispatcher.vl_q;

  // Per-lane vector FP flags bus (the dispatcher's fflags inputs) for §3.14.
  logic [NrLanes-1:0][4:0] fflags_p;
  logic [NrLanes-1:0]      fflags_valid_p;
  assign fflags_p       = i_dut.i_ara.i_dispatcher.fflags_ex_i;
  assign fflags_valid_p = i_dut.i_ara.i_dispatcher.fflags_ex_valid_i;

  vec_commit_log_pkt_t vec_beat;
  logic                vec_valid, vec_ready, vec_overflow;

  instr_tracer_synth_vec #(
    .NrLanes   ( NrLanes ),
    .FifoDepth ( 4       )
  ) i_vec_tracer (
    .clk_i          ( clk   ),
    .rst_ni         ( rst_n ),
    .flush_i        ( 1'b0  ),
    .testmode_i     ( 1'b0  ),
    .commit_instr_i ( i_dut.i_ariane.commit_instr_id_commit ),
    .commit_ack_i   ( i_dut.i_ariane.commit_ack             ),
    .instr_word_i   ( { i_dut.i_ariane.commit_instr_id_commit[1].ex.tval[31:0],
                        i_dut.i_ariane.commit_instr_id_commit[0].ex.tval[31:0] } ),
    .priv_lvl_i     ( i_dut.i_ariane.priv_lvl   ),
    .debug_mode_i   ( i_dut.i_ariane.debug_mode ),
    .vsew_i         ( vsew_p   ),
    .vlmul_i        ( vlmul_p  ),
    .vl_i           ( vl_p     ),
    .fflags_i       ( fflags_p       ),
    .fflags_valid_i ( fflags_valid_p ),
    .vrf_wen_i      ( vrf_wen_p   ),
    .vrf_addr_i     ( vrf_addr_p  ),
    .vrf_wdata_i    ( vrf_wdata_p ),
    .vrf_be_i       ( vrf_be_p    ),
    .vec_trace_valid_o ( vec_valid    ),
    .vec_trace_beat_o  ( vec_beat     ),
    .vec_trace_ready_i ( vec_ready    ),
    .overflow_o        ( vec_overflow )
  );

  // (2) consume + write the log file (simulation only).
  //     Produces: trace_hart_0_commit.synth.log in the run directory.
  instr_tracer_synth_sink #(
    .HartId     ( 64'h0   ),
    .NrLanes    ( NrLanes ),
    .EmitPktHex ( 1'b0    )    // set 1'b1 to also dump trace_hart_0.pkt.hex / .vpkt.hex
  ) i_sink (
    .clk_i             ( clk            ),
    .rst_ni            ( rst_n          ),
    .trace_valid_i     ( trace_valid    ),
    .trace_beat_i      ( trace_beat     ),
    .trace_ready_o     ( trace_ready    ),
    .overflow_i        ( trace_overflow ),
    .vec_trace_valid_i ( vec_valid      ),
    .vec_trace_beat_i  ( vec_beat       ),
    .vec_trace_ready_o ( vec_ready      ),
    .vec_overflow_i    ( vec_overflow   )
  );

  // ---------------------------------------------------------------------------
  // Run control
  // ---------------------------------------------------------------------------
  initial begin
    @(posedge rst_n);
    repeat (100_000) @(posedge clk);
    $display("[TB] finished. Trace log written to trace_hart_0_commit.synth.log");
    $finish;
  end

endmodule : tb_ara_system_trace
