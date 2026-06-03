# Hướng dẫn dùng `trace_cva6_synth` trong một project CVA6

Tài liệu này hướng dẫn **tổng quát** (không chỉ riêng Ara): vai trò từng file,
cách khởi tạo (thêm vào project), cách nối tín hiệu vào lõi CVA6, và cách chạy.

---

## A. Vai trò của TẤT CẢ các file

| File | Vai trò | Tổng hợp được? | Bắt buộc cho silicon? |
|---|---|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | **Định dạng packet**: khai báo `commit_log_pkt_t` (1 lệnh retire = 1 bản ghi nhị phân, layout cố định MSB-first) và `commit_log_beat_t` (gom các cổng commit của 1 chu kỳ). | ✅ | ✅ |
| `hardware/src/trace/instr_tracer_synth.sv` | **Module tracer chính** (DUT). Bắt tín hiệu commit-stage, mux kết quả (lấy write-back hoặc đọc shadow regfile), đóng gói thành packet, đệm vào FIFO, xuất qua cổng bắt tay `ready/valid`. | ✅ | ✅ |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | **Bể chứa — CHỈ mô phỏng.** Luôn `ready=1`, rút packet và `$fwrite` ra file hex. Mô hình hoá thứ tiêu thụ trace ngoài đời (UART/DMA). Bọc trong `` `ifndef SYNTHESIS `` + `translate_off`. | ❌ (cố ý) | ❌ |
| `hardware/tb/instr_tracer_synth_tap.sv` | **Wrapper — CHỈ mô phỏng.** Gói `instr_tracer_synth` + `instr_tracer_synth_sink` và nối chúng với nhau, để `bind` chỉ phải nối các tín hiệu *đầu vào quan sát*. | ❌ | ❌ |
| `hardware/tb/instr_tracer_synth_bind.sv` | **Câu lệnh `bind` — CHỈ mô phỏng.** Gắn `tap` vào lõi CVA6 **mà không sửa code lõi**. Đây là nơi khai báo việc nối tín hiệu. | ❌ | ❌ |
| `scripts/spike_trace_decode.py` | **Decoder host.** Đọc file packet nhị phân → in ra commit log định dạng Spike (hoặc định dạng `spike --log-commits` cho riscv-dv). Đây là phần "định dạng ASCII" được đẩy ra ngoài chip. | (Python) | (host) |
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
instr_tracer_synth.sv         # 2. module (cần fifo_v3 + cva6 pkg)
instr_tracer_synth_sink.sv    # 3. sink (sim)
instr_tracer_synth_tap.sv     # 4. tap = tracer + sink (sim)
instr_tracer_synth_bind.sv    # 5. bind (sim, phải sau khi 'ariane'/'cva6' đã có)
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
3. Chạy mô phỏng. Sink sẽ sinh file **`trace_hart_00.pkt.hex`** trong thư mục chạy
   (mỗi dòng = 1 bản ghi `commit_log_pkt_t` ở dạng hex).

> Kiểm tra transcript có dòng kiểu *"Bound instance ... instr_tracer_synth_tap"* để
> chắc `bind` đã ăn. Nếu không thấy file: kiểm tra (a) bind đúng tên module lõi,
> (b) 5 file đã nằm trong target compile của testbench.

---

## G. BƯỚC 4 — Giải mã packet → log Spike

```bash
# Định dạng commit-log của CVA6 (mặc định)
python3 scripts/spike_trace_decode.py trace_hart_00.pkt.hex -o trace_synth.log

# Định dạng 'spike --log-commits' (để dùng với riscv-dv spike_log_to_trace_csv.py)
python3 scripts/spike_trace_decode.py --format spike trace_hart_00.pkt.hex

# Lõi rv32: thêm --xlen 32 ; kèm dòng exception: --exceptions
```
Nếu project CVA6 còn chạy tracer gốc (QuestaSim), đối chiếu:
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
