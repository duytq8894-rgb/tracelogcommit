# Hướng dẫn dùng `trace_cva6_synth` trong một project CVA6

Tài liệu này hướng dẫn **tổng quát** (không chỉ riêng Ara): vai trò từng file,
cách khởi tạo (thêm vào project), cách nối tín hiệu vào lõi CVA6, và cách chạy.

---

## A. Vai trò của TẤT CẢ các file

| File | Vai trò | Tổng hợp được? | Bắt buộc cho silicon? |
|---|---|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | **Định dạng packet**: khai báo `commit_log_pkt_t` (1 lệnh retire = 1 bản ghi nhị phân, layout cố định MSB-first) và `commit_log_beat_t` (gom các cổng commit của 1 chu kỳ). | ✅ | ✅ |
| `hardware/src/trace/instr_tracer_synth.sv` | **Module tracer chính** (DUT). Bắt tín hiệu commit-stage, mux kết quả (lấy write-back hoặc đọc shadow regfile), đóng gói thành packet, đệm vào FIFO, xuất qua cổng bắt tay `ready/valid`. | ✅ | ✅ |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | **Bể chứa — CHỈ mô phỏng.** Luôn `ready=1`, **in trực tiếp commit log bằng SystemVerilog** (hàm `spike_commit_str()` tái tạo `riscv::spikeCommitLog` + `$fwrite`) ra `trace_hart_<id>_commit.synth.log` — KHÔNG cần Python. Đặt `EmitPktHex=1` để xuất thêm packet hex cho luồng silicon. Bọc trong `` `ifndef SYNTHESIS `` + `translate_off`. | ❌ (cố ý) | ❌ |
| `hardware/tb/instr_tracer_synth_tap.sv` | **Wrapper — CHỈ mô phỏng.** Gói `instr_tracer_synth` + `instr_tracer_synth_sink` và nối chúng với nhau, để `bind` chỉ phải nối các tín hiệu *đầu vào quan sát*. | ❌ | ❌ |
| `hardware/tb/instr_tracer_synth_bind.sv` | **Câu lệnh `bind` — CHỈ mô phỏng.** Gắn `tap` vào lõi CVA6 **mà không sửa code lõi**. Đây là nơi khai báo việc nối tín hiệu. | ❌ | ❌ |
| `scripts/spike_trace_decode.py` | **Decoder host — TÙY CHỌN** (cho luồng silicon). Đọc packet nhị phân → commit log Spike (hoặc định dạng `spike --log-commits` cho riscv-dv). Luồng mô phỏng KHÔNG cần file này (sink đã in bằng SV). | (Python) | (host, tùy chọn) |
| `hardware/src/trace/README.md` | Mô tả thiết kế + định dạng từng trường (tiếng Việt). | — | — |
| `hardware/src/trace/TUTORIAL.md` | Quy trình build & mô phỏng với CVA6/Ara + đối chiếu log vàng. | — | — |
| `hardware/src/trace/RISCV_DV.md` | Quy trình đồng-mô phỏng riscv-dv + Spike + tracer này. | — | — |

**Tóm tắt phân vai:** chỉ **2 file `*_pkg.sv` + `instr_tracer_synth.sv`** là phần
cứng thật (đem đi synthesis). Ba file `sink/tap/bind` là *giàn khoan kiểm chứng*
chỉ dùng khi mô phỏng. `spike_trace_decode.py` chạy trên PC.

---

## B. Phụ thuộc (phải có sẵn trong project CVA6)

`instr_tracer_synth` dùng:
1. **Package của CVA6**: `riscv` (cho `XLEN`, `priv_lvl_t`, `BREAKPOINT`) và
   `ariane_pkg` (cho `scoreboard_entry_t`, `exception_t`, `is_rd_fpr`,
   `NR_COMMIT_PORTS`). → Mọi project CVA6 đều có.
2. **Một FIFO**: hiện dùng `fifo_v3` của **common_cells** (pulp-platform). Nếu
   project CVA6 của bạn không có common_cells → thêm common_cells, **hoặc** thay
   bằng FIFO của bạn (xem mục E).

---

## C. BƯỚC 1 — Khởi tạo (thêm file vào project)

### C.1 Chép file vào cây nguồn
Giữ nguyên cấu trúc, ví dụ chép vào thư mục lõi CVA6 của bạn:
```
<cva6_project>/
├── src/trace/instr_tracer_synth_pkg.sv
├── src/trace/instr_tracer_synth.sv
├── src/trace/instr_tracer_synth_sink.sv     (sim)
├── tb/instr_tracer_synth_tap.sv             (sim)
├── tb/instr_tracer_synth_bind.sv            (sim)
└── scripts/spike_trace_decode.py            (host)
```

### C.2 Khai báo trong danh sách biên dịch — **ĐÚNG THỨ TỰ**
Phụ thuộc compile: `riscv_pkg` và `ariane_pkg` và `fifo_v3` **trước**, rồi:
```
instr_tracer_synth_pkg.sv     # 1. package định dạng
instr_tracer_addr_fifo.sv     # 2. FIFO căn địa chỉ load/store
instr_tracer_synth.sv         # 3. module (cần addr_fifo + fifo_v3 + cva6 pkg)
instr_tracer_synth_sink.sv    # 4. sink (sim)
instr_tracer_synth_tap.sv     # 5. tap = tracer + sink (sim)
instr_tracer_synth_bind.sv    # 6. bind (sim, phải sau khi 'ariane'/'cva6' đã có)
```

Ví dụ với các hệ build phổ biến:
- **Bender** (như Ara): thêm 5 file vào target test (`-t ara_test`/`-t cva6_test`).
- **Filelist `.f`** (vlog/xrun/vcs): thêm 5 dòng đường dẫn theo đúng thứ tự trên,
  sau các file của CVA6.
- **Makefile + vlog/xrun/verilator**: nối thêm 5 file vào biến nguồn của testbench.

> Phần silicon: chỉ thêm `instr_tracer_synth_pkg.sv` + `instr_tracer_synth.sv` vào
> danh sách synthesis; KHÔNG thêm sink/tap/bind.

---

## D. BƯỚC 2 — Nối tín hiệu vào lõi CVA6

Có **2 phương án**. Khuyến nghị Phương án 1 (`bind`) vì không phải sửa lõi.

### D.1 Phương án 1 — `bind` (không xâm lấn) ✅
`instr_tracer_synth_bind.sv` đã gắn `tap` vào module lõi. **Chỉ cần chỉnh 2 thứ**
cho khớp phiên bản CVA6 của bạn:

**(a) Tên module lõi** sau từ khoá `bind`:
- CVA6 fork pulp-platform / Ara: module tên **`ariane`** → `bind ariane ...`
- CVA6 OpenHW mới: thường tên **`cva6`** → đổi thành `bind cva6 ...`

**(b) Tên tín hiệu nội bộ** trong ngoặc (vế phải). Đây là các net *bên trong* lõi.
Bảng mapping (ngữ nghĩa → tên ở CVA6 pulp/Ara — chỗ này đã điền sẵn):

| Cổng module (`instr_tracer_synth`) | Ý nghĩa | Tín hiệu CVA6 (pulp/Ara) |
|---|---|---|
| `clk_i`, `rst_ni` | clock / reset | `clk_i`, `rst_ni` (cổng lõi) |
| `commit_instr_i` | scoreboard entry của lệnh retire `[NR_COMMIT_PORTS]` | `commit_instr_id_commit` |
| `commit_ack_i` | lệnh retire trong chu kỳ này | `commit_ack` |
| `instr_word_i` | **mã lệnh thô** (32-bit) | `commit_instr_id_commit[p].ex.tval[31:0]` |
| `waddr_i` | địa chỉ ghi thanh ghi | `waddr_commit_id` |
| `wdata_i` | dữ liệu write-back | `wdata_commit_id` |
| `we_gpr_i` / `we_fpr_i` | cho phép ghi GPR / FPR | `we_gpr_commit_id` / `we_fpr_commit_id` |
| `priv_lvl_i` | mức đặc quyền | `priv_lvl` |
| `debug_mode_i` | đang ở debug mode | `debug_mode` |
| `exception_i` | exception/interrupt đã retire | `commit_stage_i.exception_o` |
| `csr_commit_i` | CSR instr commit | `csr_commit_commit_ex` |
| `csr_op_i` | op CSR (write/set/clear) | `csr_op_commit_csr` |
| `csr_waddr_i` | địa chỉ CSR | `csr_addr_ex_csr` |
| `csr_operand_i` | operand (rs1/zimm) | `csr_wdata_commit_csr` |
| `csr_old_i` | giá trị CSR cũ | `csr_rdata_csr_commit` |
| `st_valid_i` | store được nạp vào store buffer | `ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i` |
| `st_paddr_i` | địa chỉ vật lý store | `…store_buffer_i.paddr_i` |
| `st_data_i` | dữ liệu store (đã `data_align`) | `…store_buffer_i.data_i` |
| `st_size_i` | kích thước store | `…store_buffer_i.data_size_i` |
| `ld_valid_i` / `ld_kill_i` | load tạo địa chỉ / bị huỷ | `ex_stage_i.lsu_i.i_load_unit.req_port_o.tag_valid` / `.kill_req` |
| `ld_paddr_i` | địa chỉ vật lý load | `…i_load_unit.paddr_i` |
| `ld_size_i` | kích thước load (đúng cả RVC) | `…i_load_unit.req_port_o.data_size` |
| `flush_addr_i` | flush pipeline → xoá FIFO địa chỉ | `flush_ctrl_ex` |

> Các tín hiệu LSU dùng cho token `mem 0x<addr> 0x<data>` (load/store); các tín hiệu
> CSR dùng cho token `c<addr> 0x<value>` (csrrw/csrrs/csrrc). Nếu không cần:
> nối `st_valid_i=ld_valid_i=0`, `flush_addr_i=0` (tắt mem) và `csr_commit_i=0`
> (tắt CSR) — phần còn lại để mặc định.
>
> ⚠️ Giá trị CSR là **post-op, pre-WARL** (tái dựng từ op+old+operand). Với CSR có
> WARL (mstatus/mip/satp/sepc…) sẽ lệch giá trị post-WARL của Spike vài bit — đúng
> theo lựa chọn non-invasive (không sửa CVA6).

> **Cách tìm tên cho phiên bản CVA6 khác:** mở file lõi (`ariane.sv`/`cva6.sv`) và
> tìm phần nối **`instr_tracer`/`tracer_if`** (tracer mô phỏng gốc) — nó dùng đúng
> những tín hiệu này. Copy tên từ các dòng `assign tracer_if.* = ...;`. Nếu lõi của
> bạn có **RVFI** (RISC-V Formal Interface), có thể nối `instr_word_i/commit/…` từ
> các tín hiệu `rvfi_*` tương ứng (sạch hơn, ổn định hơn giữa các version).

> **Lưu ý `instr_word_i`:** CVA6 nhồi mã lệnh vào `ex.tval` khi *không* có exception
> (decoder). Đó là lý do nối `commit_instr_id_commit[p].ex.tval[31:0]`. Nếu lõi có
> sẵn thanh ghi mã-lệnh ở commit-stage thì nối thẳng tín hiệu đó tốt hơn.

### D.2 Phương án 2 — Instantiate trực tiếp trong lõi (xâm lấn)
Nếu được phép sửa lõi: đặt instance ngay cạnh tracer gốc trong `ariane.sv`/`cva6.sv`:
```systemverilog
instr_tracer_synth #(.FifoDepth(32)) i_instr_tracer_synth (
  .clk_i, .rst_ni, .flush_i(1'b0), .testmode_i(1'b0),
  .commit_instr_i ( commit_instr_id_commit ),
  .commit_ack_i   ( commit_ack             ),
  .instr_word_i   ( { commit_instr_id_commit[1].ex.tval[31:0],
                      commit_instr_id_commit[0].ex.tval[31:0] } ),
  .waddr_i        ( waddr_commit_id   ), .wdata_i ( wdata_commit_id ),
  .we_gpr_i       ( we_gpr_commit_id  ), .we_fpr_i( we_fpr_commit_id ),
  .priv_lvl_i     ( priv_lvl ), .debug_mode_i ( debug_mode ),
  .exception_i    ( commit_stage_i.exception_o ),
  // nối cổng ra tới UART / AXI-DMA / debug-port / bộ đệm on-chip:
  .trace_valid_o (), .trace_beat_o (), .trace_ready_i (1'b1), .overflow_o ()
);
```
> `{port1, port0}` ghép 2 mã lệnh vào vector `[NR_COMMIT_PORTS-1:0][31:0]`
> (port 1 ở nửa cao). Nếu lõi đơn-issue (`NR_COMMIT_PORTS==1`) thì chỉ còn 1 phần tử.

---

## E. (Tùy chọn) Thay FIFO nếu không có common_cells

Trong `instr_tracer_synth.sv`, khối `fifo_v3` có giao diện chuẩn
`push_i/full_o/data_i` ⇄ `pop_i/empty_o/data_o`. Thay bằng FIFO của bạn với cùng
ngữ nghĩa: `push_i = any_valid & ~full`, `trace_valid_o = ~empty`,
`pop_i = trace_valid_o & trace_ready_i`. Dữ liệu FIFO là `commit_log_beat_t`.

---

## F. BƯỚC 3 — Chạy mô phỏng

1. Biên dịch project CVA6 (đã thêm 5 file + bind) bằng simulator của bạn
   (QuestaSim / VCS / Xcelium / Verilator).
2. Nạp một chương trình test (ELF/hex) như bình thường của project.
3. Chạy mô phỏng. Sink **in trực tiếp bằng SystemVerilog** ra file
   **`trace_hart_0_commit.synth.log`** (định dạng commit log Spike, mỗi dòng 1 lệnh).

> Kiểm tra transcript có dòng kiểu *"Bound instance ... instr_tracer_synth_tap"* để
> chắc `bind` đã ăn. Nếu không thấy file: kiểm tra (a) bind đúng tên module lõi,
> (b) 5 file đã nằm trong target compile của testbench.

---

## G. BƯỚC 4 — Đối chiếu log

Sink đã in sẵn `trace_hart_0_commit.synth.log` (không cần Python). Nếu project CVA6
còn chạy tracer gốc (QuestaSim), đối chiếu trực tiếp:
```bash
diff trace_hart_0_commit.log trace_hart_0_commit.synth.log   # rỗng = khớp từng dòng
```

### (Tùy chọn) Luồng nhị phân + decoder Python — chỉ khi cần cho silicon/riscv-dv
Bật `EmitPktHex=1` ở sink để xuất thêm `trace_hart_0.pkt.hex`, rồi:
```bash
# Định dạng commit-log của CVA6
python3 scripts/spike_trace_decode.py trace_hart_0.pkt.hex -o trace_synth.log
# Định dạng 'spike --log-commits' (cho riscv-dv spike_log_to_trace_csv.py)
python3 scripts/spike_trace_decode.py --format spike trace_hart_0.pkt.hex
# Lõi rv32: thêm --xlen 32 ; kèm dòng exception: --exceptions
```
Đối chiếu (nếu muốn):
```bash
diff trace_hart_0_commit.log trace_synth.log   # rỗng = khớp từng dòng
```

---

## H. Đưa ra ngoài chip thật (silicon)

Khi tổng hợp thật: chỉ giữ `instr_tracer_synth_pkg.sv` + `instr_tracer_synth.sv`,
instantiate trong lõi (Phương án 2) và **nối cổng `trace_*` tới một kênh xuất**:
UART, AXI-DMA ghi vào RAM, hoặc debug trace-port. Bên PC, thu luồng nhị phân rồi
chạy `spike_trace_decode.py` để ra log Spike. Cổng `ready/valid` cho phép backpressure;
`overflow_o` báo khi FIFO đầy và một beat bị mất (tăng `FifoDepth` nếu cần).
