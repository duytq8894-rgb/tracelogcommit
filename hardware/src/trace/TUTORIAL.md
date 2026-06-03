# Hướng dẫn mô phỏng module `instr_tracer_synth` với lõi CVA6

Tài liệu này liệt kê **tất cả các bước + lệnh** để mô phỏng module trace tổng hợp
được (`instr_tracer_synth`) cùng lõi CVA6 trong Ara, rồi **đối chiếu** log do nó
sinh ra với log Spike "vàng" của tracer gốc để chứng minh tương đương.

> Tất cả lệnh chạy từ thư mục gốc repo: `/home/vsi5912/ara` (gọi tắt `$ARA`).

---

## Phần 0 — Tích hợp (ĐÃ LÀM SẴN trong repo này)

Các file sau đã được thêm và nối vào thiết kế, **bạn không cần làm lại**:

| File | Vai trò |
|---|---|
| `hardware/src/trace/instr_tracer_synth_pkg.sv` | Định dạng packet nhị phân |
| `hardware/src/trace/instr_tracer_synth.sv` | Module tracer (synthesizable) |
| `hardware/src/trace/instr_tracer_synth_sink.sv` | Bể rút trace ra file (sim) |
| `hardware/tb/instr_tracer_synth_tap.sv` | Wrapper gói tracer+sink (sim) |
| `hardware/tb/instr_tracer_synth_bind.sv` | `bind` gắn vào lõi `ariane` (sim) |
| `Bender.yml` | Đã liệt kê 5 file trên trong target `ara_test` |

Cơ chế: `instr_tracer_synth_bind.sv` dùng `bind ariane ...` để **gắn không xâm lấn**
module vào mọi lõi CVA6 (`ariane`), nối thẳng vào các tín hiệu commit-stage nội bộ
mà tracer gốc dùng. Không phải sửa submodule CVA6.

Đường dẫn phân cấp: `ara_tb.dut.i_ara_soc.i_system.i_ariane` → bên trong là
`i_instr_tracer_synth_tap` (do bind tạo).

---

## Phần 1 — Yêu cầu môi trường (one-time, nặng)

Cần: toolchain RISC-V (LLVM), Spike (cho DPI), và **một** simulator
(QuestaSim *hoặc* Verilator). Trong môi trường sạch:

```bash
cd $ARA

# 1) Lấy toàn bộ submodule
git submodule update --init --recursive

# 2) Toolchain LLVM (biên dịch app) — mất khá lâu
make toolchain-llvm

# 3) Spike / riscv-isa-sim (cần cho DPI của testbench)
make riscv-isa-sim

# 4a) NẾU dùng Verilator (mã nguồn mở): build Verilator v5.012
make verilator
#  -> sinh ra install/verilator/bin/verilator(_bin)

# 4b) NẾU dùng QuestaSim: cần có 'questa-2021.2' trong PATH (license riêng)

# 5) Bender (trình quản lý nguồn HDL) + vá tech_cells
make -C hardware bender
make -C hardware apply-patches
```

> Kiểm tra nhanh: `ls install/` phải thấy `riscv-llvm`, `riscv-isa-sim`, và
> (nếu chọn Verilator) `verilator`.

---

## Phần 2 — Biên dịch một chương trình test

Dùng `hello_world` (đơn giản nhất) hoặc bất kỳ app nào trong `apps/`:

```bash
cd $ARA
make -C apps bin/hello_world
#  -> sinh ra apps/bin/hello_world (ELF) mà testbench sẽ nạp vào RAM
```

(App khác: `make -C apps bin/imatmul`, `bin/fmatmul`, `bin/dotproduct`, …)

---

## Phần 3A — Mô phỏng bằng QuestaSim  (KHUYẾN NGHỊ — có log vàng để đối chiếu)

Đây là luồng CI dùng (`make ... simc`). Quan trọng: dưới QuestaSim, **tracer gốc
cũng chạy** và sinh ra `trace_hart_0_commit.log` (log Spike vàng) để so sánh.

```bash
cd $ARA/hardware

# config mặc định: nr_lanes=4, vlen=4096
make app=hello_world simc
#  (tương đương: make app=hello_world nr_lanes=4 vlen=4096 simc)
```

Sau khi chạy xong, trong `hardware/build/` có:

| File | Nguồn |
|---|---|
| `trace_hart_0_commit.log` | **Tracer gốc** (log Spike vàng) |
| `trace_hart_0.log` | Tracer gốc (bản người-đọc disassembled) |
| `trace_hart_0_commit.synth.log` | **Module mới** — sink **in trực tiếp bằng SystemVerilog**, đúng định dạng `spikeCommitLog`, KHÔNG cần Python |

> Sink (`instr_tracer_synth_sink.sv`) format từng bản ghi bằng hàm SV
> `spike_commit_str()` (tái tạo `riscv::spikeCommitLog`) rồi `$fwrite` ra file —
> giống hệt cách tracer gốc in `trace_hart_0_commit.log`.

---

## Phần 3B — Mô phỏng bằng Verilator  (thay thế, mã nguồn mở)

Dưới Verilator, tracer gốc bị loại (`` `ifndef VERILATOR ``) nhưng module mới (RTL
thuần) vẫn chạy → vẫn có `trace_hart_0_commit.synth.log` (sink in trực tiếp bằng SV).
Không có log vàng để diff trực tiếp (thay vào đó so với `spike-dasm` của file `.dasm`).

```bash
cd $ARA/hardware

# 1) Verilate + biên dịch model
make verilate
#  (thêm nr_lanes=4 vlen=4096 nếu muốn chỉ định cấu hình)

# 2) Chạy mô phỏng, nạp ELF
make app=hello_world simv
```

`trace_hart_0_commit.synth.log` xuất hiện trong thư mục chạy; kiểm tra bằng
`find hardware -name 'trace_hart_0_commit.synth.log'`.

---

## Phần 4 — Đối chiếu log

Sink đã in sẵn `trace_hart_0_commit.synth.log` bằng SystemVerilog (định dạng
`spikeCommitLog`), nên **chỉ cần diff** với log vàng của tracer gốc:

```bash
cd $ARA/hardware/build
diff trace_hart_0_commit.log trace_hart_0_commit.synth.log && \
  echo "TRÙNG KHỚP: sink synthesizable in đúng log Spike như tracer gốc."
```

### (Tùy chọn) Luồng nhị phân + decoder Python — chỉ khi cần cho silicon thật
Nếu muốn lấy packet nhị phân (vd để thử kênh xuất ra ngoài chip), bật tham số
`EmitPktHex=1` của sink → sinh thêm `trace_hart_0.pkt.hex`, rồi giải mã:

```bash
cd $ARA
python3 scripts/spike_trace_decode.py \
        hardware/build/trace_hart_0.pkt.hex \
        -o hardware/build/trace_synth_commit.log

# (tùy chọn) kèm dòng exception dưới dạng comment '#':
python3 scripts/spike_trace_decode.py --exceptions \
        hardware/build/trace_hart_00.pkt.hex | head
```

**Đối chiếu với log vàng (chỉ ở luồng QuestaSim):**

```bash
diff hardware/build/trace_hart_0_commit.log \
     hardware/build/trace_synth_commit.log && \
  echo "TRÙNG KHỚP: module synthesizable tái tạo đúng log Spike."
```

Nếu `diff` không in gì → hai log **trùng khớp từng dòng**, chứng minh module tổng hợp
được ghi lại đúng cùng thông tin commit theo định dạng Spike.

---

## Phần 5 — "Fast path" (máy đã setup sẵn, giống CI)

```bash
cd $ARA
git submodule update --init --recursive -- hardware
make -C hardware apply-patches
make -C apps bin/hello_world
make -C hardware app=hello_world simc
python3 scripts/spike_trace_decode.py hardware/build/trace_hart_00.pkt.hex \
        -o hardware/build/trace_synth_commit.log
diff hardware/build/trace_hart_0_commit.log hardware/build/trace_synth_commit.log
```

---

## Ghi chú / xử lý sự cố

- **Không thấy `trace_hart_00.pkt.hex`**: kiểm tra `bind` đã được biên dịch chưa
  (grep transcript: `Bound ... instr_tracer_synth_tap`). Đảm bảo dùng target
  `ara_test` (luồng `simc`/`simv` đã bật sẵn qua `-t ara_test -t cva6_test`).
- **Sai số chữ số hex**: dùng đúng `--xlen` (mặc định 64). Định dạng Spike luôn in
  PC/result 16 chữ số (vì `spikeCommitLog` hardcode `logic[63:0]`) — decoder đã xử lý.
- **Lệnh debug-mode**: cả tracer gốc lẫn decoder đều bỏ qua khỏi commit log → khớp.
- **`overflow`**: nếu FIFO đầy (cổng ra ngoài chậm), sink in cảnh báo
  `trace FIFO overflow`. Trong sim, sink luôn `ready=1` nên thường không xảy ra; nếu
  có, tăng `FifoDepth` trong `instr_tracer_synth_tap.sv`.
- **Đổi app / cấu hình**: thay `app=<tên>`; đổi `nr_lanes=`/`vlen=` hoặc
  `config=<tên>` (xem `config/*.mk`).
```
