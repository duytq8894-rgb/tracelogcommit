# Đồng-mô phỏng riscv-dv ↔ Spike ↔ `instr_tracer_synth` (DUT = CVA6/Ara)

Mục tiêu: dùng **google/chipsalliance riscv-dv** sinh test ngẫu nhiên, chạy trên
**Spike (ISS, mô hình tham chiếu)** và trên **DUT (CVA6+Ara)** — nơi
`instr_tracer_synth` sinh trace — rồi **so sánh** bằng bộ công cụ của riscv-dv.

## 0. Ý tưởng then chốt (vì sao tích hợp gọn)

riscv-dv so sánh hai file CSV cùng schema. Thay vì tự tái tạo schema CSV của
riscv-dv (hay đổi giữa các phiên bản), ta cho decoder xuất **đúng định dạng
`spike --log-commits`** (`--format spike`). Khi đó **chính parser của riscv-dv**
(`spike_log_to_trace_csv.py`) chuyển *cả* log Spike *lẫn* log DUT sang CSV — một
nguồn schema duy nhất, không lệch phiên bản.

```
  riscv-dv (cần SV-sim: VCS/Questa)
        │  sinh  test_i.S
        ▼
   riscv64-unknown-elf-gcc  (GCC của Ara)
        │
        ├──────────────► Spike  --log-commits ──► spike_log_to_trace_csv.py ──► spike.csv  (THAM CHIẾU)
        │                                                  ▲
        └──► Ara RTL sim (+PRELOAD=test_i.elf)             │ (cùng 1 parser)
             instr_tracer_synth → trace_hart_00.pkt.hex    │
                    │ spike_trace_decode.py --format spike  │
                    └──────────────────────────────────────┘──► dut.csv      (DUT)
                                                                   │
                              compare_trace_csv.py  ◄──────────────┘  → PASS/FAIL
```

## 1. Cần cài đặt gì

```bash
cd /home/vsi5912/ara          # = $ARA

# (a) GCC RISC-V (rv64gcv) + Spike — dùng luôn flow của Ara
make toolchain-gcc            # -> install/riscv-gcc/bin/riscv64-unknown-elf-*
make riscv-isa-sim            # -> install/riscv-isa-sim/bin/spike

# (b) Một SV-simulator cho BỘ SINH của riscv-dv (UVM): VCS / Questa / Xcelium.
#     (Verilator KHÔNG chạy được generator UVM.) Ara đã hỗ trợ Questa.

# (c) riscv-dv
cd ~
git clone https://github.com/chipsalliance/riscv-dv.git
cd riscv-dv && pip3 install -r requirements.txt   # pyyaml, ...
export RISCV_DV=$PWD

# (d) Glue ĐÃ CÓ trong Ara:
#     - instr_tracer_synth (bind vào CVA6, xem README.md/TUTORIAL.md)
#     - scripts/spike_trace_decode.py có chế độ --format spike
```

Cấu hình riscv-dv tối thiểu (target scalar để bring-up):
- Chọn `--target rv64gc` (hoặc `rv64imafdc`). Để vector sau (xem mục 5).
- Bộ nhớ: test riscv-dv mặc định nạp tại `0x8000_0000` — **trùng** DRAM của Ara
  (`ara_tb.sv: DRAMAddrBase = 0x8000_0000`), nên không phải sửa linker.
- `riscv-dv/target/rv64gc/riscv_core_setting.sv`: `XLEN=64`, `supported_isa`,
  privileged modes khớp CVA6.

## 2. Biến môi trường cho riscv-dv

```bash
export ARA=/home/vsi5912/ara
export RISCV_GCC=$ARA/install/riscv-gcc/bin/riscv64-unknown-elf-gcc
export RISCV_OBJCOPY=$ARA/install/riscv-gcc/bin/riscv64-unknown-elf-objcopy
export SPIKE_PATH=$ARA/install/riscv-isa-sim/bin            # chứa 'spike'
```

## 3. Bước A — sinh test + biên dịch + chạy Spike tham chiếu (riscv-dv lo)

```bash
cd $RISCV_DV
python3 run.py \
  --target    rv64gc \
  --test      riscv_arithmetic_basic_test \
  --iss       spike \
  --simulator questa \
  --steps     gen,gcc_compile,iss_sim \
  -o          out/
```
Sinh ra:
- ELF test:   `out/asm_test/riscv_arithmetic_basic_test_0.o`
- CSV tham chiếu Spike: `out/spike_sim/riscv_arithmetic_basic_test_0.csv`

## 4. Bước B — chạy CÙNG ELF đó trên DUT (Ara) và lấy trace

`instr_tracer_synth` đã được bind vào CVA6 → mọi lần mô phỏng đều sinh
`trace_hart_00.pkt.hex`. Nạp thẳng ELF của riscv-dv (không qua `apps/`):

**Verilator (gọn nhất):**
```bash
cd $ARA/hardware
make verilate                       # build model 1 lần
./build/verilator/Vara_tb_verilator \
  -l ram,$RISCV_DV/out/asm_test/riscv_arithmetic_basic_test_0.o,elf
#  -> sinh trace_hart_00.pkt.hex trong thư mục chạy
```

**QuestaSim:** chạy vsim với `+PRELOAD` trỏ tới ELF riscv-dv (thay vì `app=`):
```bash
cd $ARA/hardware/build
questa-2021.2 vsim -c work.ara_tb -voptargs=+acc \
  +PRELOAD=$RISCV_DV/out/asm_test/riscv_arithmetic_basic_test_0.o \
  -sv_lib work-dpi/ara_dpi -do "run -a; quit" \
#  -> trace_hart_00.pkt.hex  (và trace_hart_0_commit.log của tracer gốc)
```

## 5. Bước C — chuyển trace DUT sang CSV của riscv-dv (qua chính parser của nó)

```bash
cd $ARA
# 5.1 packet nhị phân -> dòng định dạng 'spike --log-commits'
python3 scripts/spike_trace_decode.py --format spike --hart 0 \
        hardware/.../trace_hart_00.pkt.hex -o dut.spike.log

# 5.2 dùng parser CHÍNH CHỦ của riscv-dv -> CSV cùng schema với tham chiếu
python3 $RISCV_DV/scripts/spike_log_to_trace_csv.py \
        --log dut.spike.log --csv dut.csv
```

## 6. Bước D — so sánh

```bash
python3 $RISCV_DV/scripts/compare_trace_csv.py \
  --csv_file_1 $RISCV_DV/out/spike_sim/riscv_arithmetic_basic_test_0.csv \
  --csv_file_2 dut.csv \
  --in_order_mode 1 \
  --verbose 1
#  -> "[PASSED]" nếu DUT và Spike khớp PC + ghi thanh ghi từng lệnh.
```

Vòng nhiều test: `--iterations N` trong `run.py`, lặp bước B–D cho từng `_i.o`.

## 7. Lưu ý / giới hạn

- **Generator cần SV-sim** (VCS/Questa/Xcelium). Verilator chỉ chạy *mô phỏng RTL*
  (bước B), không chạy *bộ sinh* riscv-dv.
- **Bắt đầu với ISA vô hướng** (rv64gc). So sánh **vector (V)** khó hơn nhiều:
  Spike mô hình hoá V khác Ara, và lệnh vector trên Ara không retire ghi GPR vô
  hướng như Spike → ngoài phạm vi bring-up cơ bản. Tracer này log ghi GPR/FPR tại
  commit của CVA6 (phần vô hướng).
- **Bootrom / căn lệ đầu trace**: nếu CVA6 chạy boot trước test, lọc trace từ PC
  `0x8000_0000` (hoặc dùng begin/end signature của riscv-dv) trước khi so sánh.
- **CSR/interrupt**: log commit cơ bản chỉ so PC + ghi thanh ghi. So CSR cần thêm
  trường — bổ sung sau nếu cần.
- `mode`/privilege: tracer in 3/1/0 (M/S/U) y như Spike → cột `mode` khớp.
```
