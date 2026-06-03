# Bộ trace lệnh tổng hợp được (synthesizable) cho lõi CVA6

Thư mục này chứa một **bản dựng lại có thể tổng hợp được (synthesizable)** của module
`instr_tracer` vốn chỉ dùng cho mô phỏng trong CVA6. Mục tiêu: ghi lại **cùng một
lượng thông tin** và tái tạo **đúng định dạng commit log của Spike**
(`riscv::spikeCommitLog()`), nhưng bằng RTL chạy được trên phần cứng thật (FPGA/ASIC).

## 1. Vì sao `instr_tracer` gốc KHÔNG tổng hợp được

`hardware/deps/cva6/src/util/instr_tracer.sv` (và `instr_trace_item.svh`,
`ex_trace_item.svh`, `instr_tracer_if.sv`) chỉ là mô hình kiểm chứng. Toàn bộ được
bọc trong `` `ifndef VERILATOR `` và `//pragma translate_off`. Nó dùng các cấu trúc
**không tổng hợp được**:

| Cấu trúc trong tracer gốc | Vì sao không tổng hợp được |
|---|---|
| `class instr_trace_item`, `new(...)` | Lập trình hướng đối tượng, cấp phát động |
| Hàng đợi động `logic [31:0] decode_queue [$]` | Mảng động kích thước vô hạn |
| `string`, `$sformatf`, `$sformat` | Kiểu chuỗi + định dạng văn bản |
| `$fopen`, `$fwrite`, `$fclose`, `$display` | Vào/ra tệp |
| `interface` + `clocking pck @(posedge clk)` | Clocking block chỉ cho testbench |
| `initial`, `final`, `forever`, `task` | Cấu trúc stimulus mô phỏng |
| `time`, `$time` | Thời gian mô phỏng |
| `case (instr) inside` với mẫu `?` | Khớp wildcard để giải mã mnemonic |

Điểm mấu chốt: **không thể tổng hợp việc tạo chuỗi ASCII và ghi tệp**. Phần cứng
không có khái niệm "tệp" hay "chuỗi". Vì vậy ta tách bài toán làm hai:

```
   TRÊN CHIP (tổng hợp được)          NGOÀI CHIP (host)
   ───────────────────────           ─────────────────
   Bắt commit + đóng gói nhị phân  →  Giải mã nhị phân → ASCII Spike
   (instr_tracer_synth.sv)            (spike_trace_decode.py)
```

Đây đúng là cách luồng Verilator đang làm: nó ghi `DASM(%h)` rồi để công cụ
`spike-dasm` ngoài chip dịch ngược. Ta áp dụng đúng nguyên lý đó.

## 2. Ánh xạ "cùng kỹ thuật" sang phần cứng

| Tracer mô phỏng | Module tổng hợp được |
|---|---|
| `class` / `new` | `struct packed` (`commit_log_pkt_t`) |
| Hàng đợi động `[$]` | FIFO phần cứng độ sâu cố định (`fifo_v3`) |
| `string` + `$sformatf` | Bản ghi nhị phân layout cố định |
| `$fopen` / `$fwrite` | Cổng streaming bắt tay `ready/valid` |
| `interface` + clocking block | Cổng module thường (packed struct) |
| `initial` / `forever` / `task` | `always_ff` / `always_comb` |
| `gp_reg_file`/`fp_reg_file` (shadow) | Mảng thanh ghi shadow tổng hợp được |

## 3. Các tệp

| Tệp | Vai trò | Tổng hợp được? |
|---|---|---|
| `instr_tracer_synth_pkg.sv` | Định nghĩa bản ghi nhị phân `commit_log_pkt_t` / `commit_log_beat_t` | ✅ |
| `instr_tracer_synth.sv` | Module tracer: bắt commit, mux kết quả, đóng gói, đệm FIFO, xuất ra cổng `ready/valid` | ✅ |
| `instr_tracer_synth_sink.sv` | "Bể chứa" rút trace ra tệp hex — **chỉ dùng mô phỏng** (bọc `` `ifndef SYNTHESIS `` + `translate_off`) | ❌ (cố ý) |
| `../../../scripts/spike_trace_decode.py` | Decoder host: nhị phân → commit log Spike | (script Python) |

## 4. Định dạng bản ghi `commit_log_pkt_t`

Đóng gói **MSB-first** đúng theo thứ tự khai báo trong struct:

```
priv[2] debug[1] ex_valid[1] compressed[1] we[1] rd_fpr[1] rd[5]
pc[XLEN] instr[32] wdata[XLEN] cause[XLEN] tval[XLEN]
```

Với `XLEN=64` mỗi bản ghi rộng `300` bit. Một "beat" gom đủ `NR_COMMIT_PORTS`
cổng commit của cùng một chu kỳ để giữ đúng **thứ tự chương trình** (cổng 0 là lệnh
cũ hơn) khi đi qua FIFO.

Các trường này chính là đầu vào của `riscv::spikeCommitLog()`: `priv, pc, instr,
rd (+ cờ fpr), result`. Quy tắc in của Spike được tái tạo nguyên vẹn trong decoder:

```
0 0x0000000080000118 (0xeecf8f93) x31 0x0000000080004000   ← có ghi rd
0 0x000000008000019c (0x0040006f)                          ← không ghi rd
```

- `priv` in dạng số thập phân (M=3, S=1, U=0).
- `pc`, `result`: `0x` + `XLEN/4` chữ số hex (đệm 0).
- Lệnh nén RVC (`instr[1:0] != 2'b11`): `(0x%04x)`; còn lại `(0x%08x)`.
- Tên thanh ghi: `x`/`f` + số; có **dấu cách** khi `rd < 10` (`x 8`), không dấu cách
  khi `rd >= 10` (`x31`).
- Chỉ in dòng `rd` khi `rd_fpr || rd != 0`.

## 5. Cách dùng / tích hợp vào `ariane.sv`

Thay cho khối `instr_tracer_if`/`instr_tracer` (đang bọc `` `ifndef VERILATOR ``),
nối thẳng các tín hiệu commit-stage vào module tổng hợp được:

```systemverilog
instr_tracer_synth #(.FifoDepth(32)) i_instr_tracer_synth (
  .clk_i, .rst_ni, .flush_i(1'b0), .testmode_i(1'b0),
  .commit_instr_i ( commit_instr_id_commit ),
  .commit_ack_i   ( commit_ack             ),
  // CVA6 nhồi instruction word vào ex.tval khi không có exception:
  .instr_word_i   ( '{commit_instr_id_commit[1].ex.tval[31:0],
                      commit_instr_id_commit[0].ex.tval[31:0]} ),
  .waddr_i        ( waddr_commit_id        ),
  .wdata_i        ( wdata_commit_id        ),
  .we_gpr_i       ( we_gpr_commit_id       ),
  .we_fpr_i       ( we_fpr_commit_id       ),
  .priv_lvl_i     ( priv_lvl               ),
  .debug_mode_i   ( debug_mode             ),
  .exception_i    ( commit_stage_i.exception_o ),
  // cổng trace ra: nối tới UART / AXI-DMA / debug port / bộ đệm on-chip
  .trace_valid_o  ( trace_valid ),
  .trace_beat_o   ( trace_beat  ),
  .trace_ready_i  ( trace_ready ),
  .overflow_o     ( trace_overflow )
);
```

> Lưu ý nguồn `instr_word_i`: bộ giải mã CVA6 lưu mã lệnh vào
> `commit_instr_i[p].ex.tval[31:0]` khi `~ex.valid` (xem `decoder.sv:1157`), đúng như
> mock Verilator dùng. Nếu lõi có sẵn thanh ghi mã lệnh ở commit-stage thì nên nối
> trực tiếp tín hiệu đó.

## 6. Luồng mô phỏng → log Spike (kiểm chứng)

```bash
# 1) Mô phỏng có nối instr_tracer_synth + instr_tracer_synth_sink
#    -> sinh ra tệp trace_hart_00.pkt.hex (mỗi dòng = 1 bản ghi hex)

# 2) Giải mã ngoài chip thành commit log Spike:
python3 scripts/spike_trace_decode.py --xlen 64 trace_hart_00.pkt.hex -o trace_spike.log

# (tùy chọn) kèm cả dòng exception dưới dạng comment '#':
python3 scripts/spike_trace_decode.py --xlen 64 --exceptions trace_hart_00.pkt.hex
```

So sánh `trace_spike.log` với log `trace_hart_0_commit.log` do tracer gốc sinh ra để
kiểm chứng tính tương đương.

## 7. Backpressure & overflow

Cổng ra dùng bắt tay `ready/valid`. Nếu phía tiêu thụ chậm và FIFO đầy, một beat sẽ
bị bỏ; khi đó `overflow_o` lên `1` để báo trace **đã có lỗ hổng** (không tái tạo
liên tục được). Tăng `FifoDepth` hoặc tăng băng thông cổng ra để tránh.
