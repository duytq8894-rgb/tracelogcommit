# Cấu trúc Spike Commit Log — RIÊNG cho lệnh Vector (RVV)

> Dùng để viết module tracer SystemVerilog (synthesizable) cho co-sim CVA6 + ARA vs Spike.
> Mục tiêu: in ra dòng log **giống format Spike** từ tín hiệu RTL, để diff trực tiếp với commit log của Spike.
> Giả định: `VLEN=128`, `SEW`/`LMUL` theo từng ví dụ, privilege M (`priv=3`).
>
> **Cảnh báo phiên bản:** format in `v<n>` thay đổi giữa các bản Spike (per-element cũ vs hex-string mới).
> Khớp đúng git hash của Spike đang dùng.

---

## 0. Mô hình chung: tracer cần lấy gì từ RTL

Mỗi khi một lệnh **retire/commit**, tracer ghép một dòng từ các nguồn tín hiệu RTL:

| Thành phần dòng log | Lấy từ tín hiệu RTL (CVA6/ARA) |
|---------------------|-------------------------------|
| `core <id>` | hart ID (hằng số) |
| `priv` | `priv_lvl_q` của CSR |
| `pc` | PC của lệnh tại commit stage |
| `insn_bits` | instruction encoding tại commit |
| `disasm` | (tùy chọn) — có thể bỏ nếu chỉ cần diff state |
| vector writeback | VRF write port: `vrf_we`, `vrf_waddr`, `vrf_wdata`, byte-enable |
| scalar writeback | GPR/FPR write port: `we`, `waddr`, `wdata` |
| CSR writeback | CSR write: addr + new value (vtype/vl/vstart/fflags/vxsat) |
| memory write | store unit: `addr`, `wdata`, byte-strobe per element |

**Nguyên tắc vàng:** một dòng = một lệnh, nhưng phần writeback có thể chứa **nhiều token** (nhiều `v<n>` khi LMUL>1, nhiều `mem` khi store nhiều element). Tracer phải lặp.

---

## 1. Format tổng quát một dòng (phần header)

```
core <id>: <priv> <pc> (<insn_bits>) <disasm>  <writeback...>
```

Thứ tự cố định: **header trước, writeback sau**. Writeback in theo thứ tự: register writes → memory writes.

| Trường | Định dạng in | Ví dụ |
|--------|--------------|-------|
| `core` | `core %3d` | `core   0` |
| `priv` | `%d` (3/1/0) | `3` |
| `pc` | `0x%016x` (RV64) | `0x0000000080000184` |
| `insn` | `(0x%08x)` | `(0x02208157)` |

Prefix phân loại register theo 2-bit tag của Spike (`item.first & 3`):

| Tag | Loại | Prefix in ra |
|-----|------|--------------|
| 0 | Integer | `x<n>` |
| 1 | Float | `f<n>` |
| 2 | CSR | `c<addr>_<name>` |
| 3 | **Vector** | `v<n>` |

---

## 2. Quy ước sắp xếp & endianness (CỰC KỲ QUAN TRỌNG cho tracer)

### 2.1. Thứ tự element trong chuỗi hex `v<n>`
- **Element cao bên TRÁI (MSB), element 0 bên PHẢI (LSB).**
- In **toàn bộ VLEN bits**, KHÔNG mask theo `vl`/`vstart`/`vta`/`vma`.

```
v2 0x 00000004 00000003 00000002 00000001
        elem[3]  elem[2]  elem[1]  elem[0]
```
→ Trong SV: lấy thẳng `vrf_data[VLEN-1:0]` rồi in `%032x`. RTL lưu little-endian theo element nên thường khớp tự nhiên, **nhưng phải verify** bằng một lệnh `vid.v` đã biết kết quả.

### 2.2. Thứ tự `mem` (store)
- Mỗi element store → một cặp `mem <addr> <value>`.
- Thứ tự in theo **thứ tự element** (element 0 trước), KHÔNG theo địa chỉ.
- Với indexed store, địa chỉ có thể **không tăng dần**.

### 2.3. Load KHÔNG có `mem`
Commit log chỉ log memory **write**. Vector load chỉ thể hiện qua nội dung `v<n>` đích.

---

## 3. Từng trường hợp lệnh vector — IN GÌ / LẤY ĐÂU / SẮP XẾP

### 3.1. `vsetvli` / `vsetvl` / `vsetivli`
**In gì:** scalar `x<rd>` (= vl mới) + CSR `vtype` + CSR `vl`.
**Lấy ở đâu:** `rd` write port (vl mới); CSR write port cho vtype/vl.
**Sắp xếp:** `x<rd>` trước, rồi `c<vtype>`, rồi `c<vl>`.
```
core   0: 3 0x0000000080000180 (0x0185f2d7) vsetvli t0, a1, e32,m1,ta,ma  x5 0x0000000000000004 c3104_vtype 0x0000000000000010 c3105_vl 0x0000000000000004
```
- `x5=4` → vl=4 (128/32). `c3104`=vtype, `c3105`=vl.
- Tracer: chỉ lệnh này cập nhật vtype/vl → phải snoop CSR write của vsetvl chứ không phải GPR thường.

---

### 3.2. `vadd.vv` — vector-vector
**In gì:** chỉ vector register đích `v<rd>`.
**Lấy ở đâu:** VRF write port (waddr=rd, wdata=toàn bộ VLEN).
**Sắp xếp:** một token `v<rd>`, full VLEN, element 0 bên phải.
```
core   0: 3 0x0000000080000184 (0x02208157) vadd.vv v2, v2, v1  v2 0x00000004000000030000000200000001
```

---

### 3.3. `vadd.vx` — vector-scalar
**In gì:** vector đích `v<rd>`. Operand scalar (rs1) đọc từ GPR — KHÔNG in.
**Lấy ở đâu:** VRF write port.
**Sắp xếp:** giống 3.2.
```
core   0: 3 0x0000000080000188 (0x040640d7) vadd.vx v1, v0, a2  v1 0x0000000a000000090000000800000007
```

---

### 3.4. `vle32.v` — unit-stride load
**In gì:** chỉ `v<rd>` (dữ liệu load về). KHÔNG có `mem`.
**Lấy ở đâu:** VRF write port sau khi load hoàn tất.
**Sắp xếp:** một token `v<rd>`.
```
core   0: 3 0x000000008000018c (0x0205e107) vle32.v v2, (a1)  v2 0x44434241343332312423222114131211
```
- Tracer: KHÔNG in địa chỉ đọc, KHÔNG in `mem`.

---

### 3.5. `vse32.v` — unit-stride store
**In gì:** KHÔNG ghi register. Nhiều cặp `mem <addr> <value>`, mỗi element một cặp.
**Lấy ở đâu:** store unit — mỗi beat ghi memory: addr + data element.
**Sắp xếp:** theo thứ tự element (elem 0 → elem n), value là dữ liệu của element đó.
```
core   0: 3 0x0000000080000190 (0x0205e1a7) vse32.v v3, (a2)  mem 0x80002000 0x11121314 mem 0x80002004 0x21222324 mem 0x80002008 0x31323334 mem 0x8000200c 0x41424344
```
- Tracer: lặp đúng số element = vl; addr = base + i*EEW/8.

---

### 3.6. `vlse32.v` — strided load
**In gì:** `v<rd>`. KHÔNG có `mem`.
**Lấy ở đâu:** VRF write port.
**Sắp xếp:** một token `v<rd>`; stride không hiện trong log.
```
core   0: 3 0x0000000080000194 (0x0a85e207) vlse32.v v4, (a1), a6  v4 0x00000040000000300000002000000010
```

---

### 3.7. `vluxei32.v` / `vloxei32.v` — indexed load
**In gì:** `v<rd>`. KHÔNG có `mem`.
**Lấy ở đâu:** VRF write port. Index vector (rs2) là operand, KHÔNG in riêng.
**Sắp xếp:** một token `v<rd>`.
```
core   0: 3 0x0000000080000198 (0x0e85e207) vluxei32.v v4, (a1), v6  v4 0x000000aa000000bb000000cc000000dd
```

---

### 3.8. `vsuxei32.v` / `vsoxei32.v` — indexed store
**In gì:** KHÔNG ghi register. Các cặp `mem <addr> <value>` với địa chỉ index hóa (CÓ THỂ không tuần tự).
**Lấy ở đâu:** store unit; addr = base + index[i].
**Sắp xếp:** theo thứ tự element (KHÔNG theo địa chỉ).
```
core   0: 3 0x000000008000019c (0x0e85e227) vsoxei32.v v3, (a1), v6  mem 0x80002010 0x11121314 mem 0x80002000 0x21222324 mem 0x80002020 0x31323334
```

---

### 3.9. `vid.v` — index generation
**In gì:** `v<rd>` chứa chỉ số element.
**Lấy ở đâu:** VRF write port.
**Sắp xếp:** một token; **dùng lệnh này để VERIFY endianness** của tracer (kết quả biết trước: elem[i]=i).
```
core   0: 3 0x00000000800100e2 (0x5208a457) vid.v v8  v8 0x00000003000000020000000100000000
```
Bản Spike cũ in per-element: `v8 : [3]: 0x00000003 [2]: 0x00000002 [1]: 0x00000001 [0]: 0x00000000`

---

### 3.10. `vmv.x.s` — vector → scalar
**In gì:** integer `x<rd>`. KHÔNG ghi vector.
**Lấy ở đâu:** GPR write port (data = element 0 của vs2).
**Sắp xếp:** một token `x<rd>`.
```
core   0: 3 0x00000000800001a0 (0x428020d7) vmv.x.s a1, v8  x11 0x0000000000000001
```

---

### 3.11. `vmv.s.x` — scalar → vector
**In gì:** `v<rd>` (chỉ element 0 đổi; element khác giữ nguyên).
**Lấy ở đâu:** VRF write port (full VLEN — phần không đổi vẫn in).
**Sắp xếp:** một token `v<rd>`.
```
core   0: 3 0x00000000800001a4 (0x4205e0d7) vmv.s.x v1, a1  v1 0x0000000a0000000900000008deadbeef
```
- `deadbeef` ở elem[0] là giá trị mới; elem[1..3] giữ nguyên.

---

### 3.12. `vredsum.vs` — reduction
**In gì:** `v<rd>`, kết quả ở element 0; element khác theo `vta`.
**Lấy ở đâu:** VRF write port.
**Sắp xếp:** một token `v<rd>`.
```
core   0: 3 0x00000000800001a8 (0x020a2157) vredsum.vs v2, v1, v0  v2 0x0000000000000000000000000000000a
```

---

### 3.13. `vmseq.vv` / `vmslt.vv` — compare → mask
**In gì:** mask register `v<rd>` (thường v0), bit-packed (1 bit/element).
**Lấy ở đâu:** VRF write port (chỉ phần thấp mang bit mask có nghĩa).
**Sắp xếp:** một token; giá trị là bitmask, bit i ứng element i.
```
core   0: 3 0x00000000800001ac (0x6220a057) vmseq.vv v0, v1, v2  v0 0x0000000000000000000000000000000d
```
- `0xd = 0b1101` → element 0,2,3 bằng; element 1 khác.

---

### 3.14. `vfadd.vv` — vector float
**In gì:** `v<rd>` + CSR `fflags`.
**Lấy ở đâu:** VRF write port + CSR write (fflags) từ FPU vector.
**Sắp xếp:** `v<rd>` trước, `c<fflags>` sau.
```
core   0: 3 0x00000000800001b0 (0x02209157) vfadd.vv v2, v2, v1  v2 0x40400000400000003f80000040000000 c1_fflags 0x0000000000000001
```

---

### 3.15. Lệnh masked (`v0.t`)
**In gì:** `v<rd>` full VLEN, GỒM cả element inactive.
**Lấy ở đâu:** VRF write port. Element inactive: undisturbed=giữ cũ, agnostic=có thể all-1s.
**Sắp xếp:** một token; phần inactive vẫn in nguyên trạng VRF.
```
core   0: 3 0x00000000800001b4 (0x02208177) vadd.vv v2, v2, v1, v0.t  v2 0x00000004cafecafe0000000200000001
```
- `cafecafe` ở elem[1] = giá trị inactive (mask=0) giữ lại.

---

### 3.16. Vector L/S gặp exception giữa chừng
**In gì:** commit log "một phần" của các element đã xong, TRƯỚC dòng trap.
**Lấy ở đâu:** VRF/store đã hoàn tất một phần khi fault xảy ra.
**Sắp xếp:** dòng commit một phần → dòng exception → dòng tval.
```
core   0: 3 0x00000000800001b8 (0x0205e107) vle32.v v2, (a1)  v2 0x00000000000000002423222114131211
core   0: exception trap_load_access_fault, epc 0x00000000800001b8
core   0: tval 0x0000000080003000
```

---

## 4. Bảng tóm tắt: lệnh nào in gì

| Loại lệnh | `v<rd>` | `x`/`f` | CSR | `mem` |
|-----------|:-------:|:-------:|:---:|:-----:|
| vsetvl* | – | x (vl) | vtype, vl | – |
| arith vv/vx/vi | ✓ | – | – | – |
| load (unit/strided/indexed) | ✓ | – | – | – |
| store (unit/strided/indexed) | – | – | – | ✓ |
| vid.v / viota | ✓ | – | – | – |
| vmv.x.s | – | x | – | – |
| vmv.s.x | ✓ | – | – | – |
| reduction (vred*) | ✓ | – | – | – |
| compare (vmseq…) | ✓ (mask) | – | – | – |
| vector float | ✓ | – | fflags | – |
| fixed-point sat | ✓ | – | vxsat | – |

---

## 5. Checklist module tracer SystemVerilog

- [ ] Trigger in dòng đúng **một lần khi lệnh commit** (không in lúc issue/execute).
- [ ] Header in trước, writeback sau; phân loại token theo prefix.
- [ ] VRF: in full `[VLEN-1:0]` bằng `%032x` (với VLEN=128); KHÔNG mask.
- [ ] Verify endianness bằng `vid.v` đã biết kết quả trước khi tin tracer.
- [ ] Store: lặp đúng `vl` element, in cặp `mem` theo thứ tự element.
- [ ] Load: KHÔNG in `mem`, chỉ in `v<rd>`.
- [ ] CSR: chỉ vsetvl in vtype/vl; float in fflags; fixed-point in vxsat.
- [ ] Xử lý masked op: vẫn in element inactive (giá trị VRF thực).
- [ ] Xử lý exception giữa vector L/S: in dòng commit một phần rồi mới trap.

---

## 6. Regex cho SystemVerilog

> SystemVerilog không có regex gốc đầy đủ như PCRE. Hai hướng:
> **(A)** dùng hàm chuỗi built-in (`$sscanf`, `substr`);
> **(B)** parse bằng DPI-C gọi regex của C.
> **Lưu ý:** nếu module là tracer **in ra** log (không parse), bạn KHÔNG cần regex — chỉ cần `$sformatf` ghép format ở mục 1–3. Regex chỉ cần khi tracer/scoreboard phải **đọc lại** log Spike để diff.

### 6.1. Pattern PCRE-style (cho DPI-C hoặc script ngoài)
```
# Header
core\s+(\d+):\s+(\d)\s+0x([0-9a-fA-F]+)\s+\((0x[0-9a-fA-F]+)\)\s+(.*)

# Token writeback (lặp / findall trên phần còn lại)
\bv(\d+)\s+0x([0-9a-fA-F]+)                 # vector reg
\bx(\d+)\s+0x([0-9a-fA-F]+)                 # int reg
\bf(\d+)\s+0x([0-9a-fA-F]+)                 # float reg
\bc(\d+)_(\w+)\s+0x([0-9a-fA-F]+)           # CSR
\bmem\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+) # memory write
```

### 6.2. Parse header thuần SystemVerilog bằng `$sscanf`
```systemverilog
int     core_id, priv;
longint pc, insn;
string  rest;

// %h đọc hex; %[^\n] (nếu simulator hỗ trợ) lấy phần còn lại làm writeback.
int n = $sscanf(line, "core %d: %d 0x%h (0x%h) %s", core_id, priv, pc, insn, rest);
if (n < 4) begin
  // không phải dòng commit (vd "exception"/"tval") -> nhánh xử lý riêng
end
```

### 6.3. Tách token writeback thuần SV
SV không có `findall`; tự split theo space rồi nhận diện prefix từng token:
```systemverilog
function automatic void parse_writeback(string s);
  int      vidx, xidx, csr_addr;
  longint  val, addr;
  // Pseudo-loop: cắt s thành các token, với mỗi token thử match:
  //   "v%d"  -> vector reg, token kế là 0x<val>
  //   "x%d"  -> int reg
  //   "f%d"  -> float reg
  //   "c%d_" -> CSR (kèm tên), token kế là 0x<val>
  //   "mem"  -> 2 token kế: 0x<addr> rồi 0x<val>
  if      ($sscanf(token, "v%d",  vidx)     == 1) begin /* vector write */ end
  else if ($sscanf(token, "x%d",  xidx)     == 1) begin /* int write   */ end
  else if ($sscanf(token, "c%d_", csr_addr) == 1) begin /* csr write   */ end
  else if (token == "mem")                          begin /* mem write  */ end
endfunction
```

### 6.4. Nếu dùng SVRegex / 3rd-party package
```systemverilog
import svregex_pkg::*;
svregex re_vreg = new("v([0-9]+)\\s+0x([0-9a-fA-F]+)");
if (re_vreg.match(rest)) begin
  vidx = re_vreg.get_match(1).atoi();
  // get_match(2) = chuỗi hex -> .atohex()
end
```

> Khuyến nghị: nếu chỉ **so sánh** trace, dùng **DPI-C + PCRE** (6.1) — nhanh và đáng tin hơn parse chuỗi thuần SV.
