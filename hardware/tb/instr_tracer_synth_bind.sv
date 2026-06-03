// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Description: Non-invasive attachment of the synthesizable instruction tracer
// to every CVA6 `ariane` core. Using `bind` means the CVA6 submodule is left
// untouched; the bound instance is resolved in the scope of `ariane`, so the
// port expressions below reference the same internal commit-stage signals that
// drive the original simulation tracer (see ariane.sv, the `assign tracer_if.*`
// block). NOT part of the synthesizable design.

`ifndef SYNTHESIS
// pragma translate_off
bind ariane instr_tracer_synth_tap #(
  .FifoDepth (32),
  .HartId    (64'h0)
) i_instr_tracer_synth_tap (
  .clk_i,
  .rst_ni,
  .commit_instr_i ( commit_instr_id_commit ),
  .commit_ack_i   ( commit_ack             ),
  // CVA6 stores the (possibly compressed) instruction word in ex.tval when no
  // exception is pending (decoder.sv:1157); {port1, port0} packs them into the
  // [NR_COMMIT_PORTS-1:0][31:0] input with port 1 in the upper half.
  .instr_word_i   ( { commit_instr_id_commit[1].ex.tval[31:0],
                      commit_instr_id_commit[0].ex.tval[31:0] } ),
  .waddr_i        ( waddr_commit_id        ),
  .wdata_i        ( wdata_commit_id        ),
  .we_gpr_i       ( we_gpr_commit_id       ),
  .we_fpr_i       ( we_fpr_commit_id       ),
  .priv_lvl_i     ( priv_lvl               ),
  .debug_mode_i   ( debug_mode             ),
  .exception_i    ( commit_stage_i.exception_o ),
  // LSU memory-access signals (for the Spike-style "mem 0x<addr> 0x<data>")
  .st_valid_i     ( ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i     ),
  .st_paddr_i     ( ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i     ),
  .st_data_i      ( ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_i      ),
  .st_size_i      ( ex_stage_i.lsu_i.i_store_unit.store_buffer_i.data_size_i ),
  .ld_valid_i     ( ex_stage_i.lsu_i.i_load_unit.req_port_o.tag_valid        ),
  .ld_kill_i      ( ex_stage_i.lsu_i.i_load_unit.req_port_o.kill_req         ),
  .ld_paddr_i     ( ex_stage_i.lsu_i.i_load_unit.paddr_i                     ),
  .ld_size_i      ( ex_stage_i.lsu_i.i_load_unit.req_port_o.data_size        ),
  .flush_addr_i   ( flush_ctrl_ex )
);
// pragma translate_on
`endif
