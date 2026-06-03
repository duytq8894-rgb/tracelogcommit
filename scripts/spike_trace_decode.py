#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Host-side decoder for the synthesizable instruction tracer
# (hardware/src/trace/instr_tracer_synth.sv).
#
# The on-chip tracer streams fixed-layout binary records (`commit_log_pkt_t`).
# This script turns each record back into one line of Spike-compatible commit
# log, reproducing exactly what `riscv::spikeCommitLog()` prints, e.g.:
#
#   0 0x0000000080000118 (0xeecf8f93) x31 0x0000000080004000
#   0 0x000000008000019c (0x0040006f)
#
# This is the synthesizable-flow equivalent of running `spike-dasm` on the
# Verilator `.dasm` file: the *formatting* lives off-chip, the *capture* is
# real hardware.
#
# Input: a text file with one record per line, each line being the raw hex of
# one `commit_log_pkt_t` (this is what instr_tracer_synth_sink.sv produces).

import argparse
import sys

# Packed field layout of commit_log_pkt_t, MSB-first (matches the SV struct).
# Each entry is (name, width-in-bits). XLEN-dependent fields use 'XLEN'.
FIELDS_MSB_FIRST = [
    ("priv",       2),
    ("debug",      1),
    ("ex_valid",   1),
    ("compressed", 1),
    ("we",         1),
    ("rd_fpr",     1),
    ("rd",         5),
    ("pc",      "XLEN"),
    ("instr",      32),
    ("wdata",   "XLEN"),
    ("cause",   "XLEN"),
    ("tval",    "XLEN"),
]


def field_widths(xlen):
    return [(n, xlen if w == "XLEN" else w) for n, w in FIELDS_MSB_FIRST]


def pkt_width(xlen):
    return sum(w for _, w in field_widths(xlen))


def unpack(value, xlen):
    """Slice one integer record into its fields (LSB-first extraction)."""
    fields = {}
    v = value
    for name, width in reversed(field_widths(xlen)):  # from LSB upward
        fields[name] = v & ((1 << width) - 1)
        v >>= width
    return fields


def spike_commit_log(f, prefix=""):
    """Reproduce riscv::spikeCommitLog() for one retired instruction.

    With prefix="core   0: " the line becomes byte-compatible with Spike's
    `--log-commits` output, so the riscv-dv parser scripts/spike_log_to_trace_csv.py
    can convert the DUT trace into the very same CSV schema it uses for the Spike
    reference (single source of truth, no schema drift)."""
    # spikeCommitLog() declares its pc/result parameters as `logic [63:0]`
    # unconditionally (riscv_pkg.sv:662), so `0x%h` always emits 16 zero-padded
    # hex digits regardless of XLEN. A 32-bit value is simply zero-extended.
    hexw = 16
    priv = f["priv"]
    pc = f["pc"]
    instr = f["instr"]
    rd = f["rd"]
    result = f["wdata"]
    rd_fpr = f["rd_fpr"]

    # 16-bit (RVC) vs 32-bit instruction word, exactly as spikeCommitLog does
    # (it keys off instr[1:0] != 2'b11).
    if (instr & 0x3) != 0x3:
        instr_word = "(0x%04x)" % (instr & 0xFFFF)
    else:
        instr_word = "(0x%08x)" % (instr & 0xFFFFFFFF)

    rf_s = "f" if rd_fpr else "x"
    # Note the (intentional) space for single-digit register numbers, kept
    # byte-for-byte identical to the SystemVerilog formatting.
    rd_s = ("%s %d" % (rf_s, rd)) if rd < 10 else ("%s%d" % (rf_s, rd))

    if rd_fpr or rd != 0:
        return prefix + "%d 0x%0*x %s %s 0x%0*x" % (priv, hexw, pc, instr_word, rd_s, hexw, result)
    return prefix + "%d 0x%0*x %s" % (priv, hexw, pc, instr_word)


# Minimal cause -> text map for the (optional) exception annotations. Mirrors
# ex_trace_item.svh. Codes follow riscv_pkg.sv.
CAUSE_STR = {
    0: "Instruction Address Misaligned",
    1: "Instruction Access Fault",
    2: "Illegal Instruction",
    3: "Breakpoint",
    4: "Load Address Misaligned",
    5: "Load Access Fault",
    6: "Store Address Misaligned",
    7: "Store Access Fault",
    8: "Environment Call User Mode",
    9: "Environment Call Supervisor Mode",
    11: "Environment Call Machine Mode",
    12: "Instruction Page Fault",
    13: "Load Page Fault",
    15: "Store Page Fault",
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("infile", nargs="?", default="-",
                    help="packed hex records, one per line ('-' for stdin)")
    ap.add_argument("-o", "--output", default="-",
                    help="output Spike commit log ('-' for stdout)")
    ap.add_argument("--xlen", type=int, default=64, choices=(32, 64),
                    help="architectural width the core was built with")
    ap.add_argument("--exceptions", action="store_true",
                    help="also emit exception records as '#' comment lines")
    ap.add_argument("--format", choices=("cva6", "spike"), default="cva6",
                    help="'cva6' (default): CVA6 commit-log format; "
                         "'spike': prepend 'core <id>: ' so the output is "
                         "drop-in for riscv-dv's spike_log_to_trace_csv.py")
    ap.add_argument("--hart", type=int, default=0,
                    help="hart id used in the 'core <id>: ' prefix (--format spike)")
    args = ap.parse_args()

    prefix = ("core   %d: " % args.hart) if args.format == "spike" else ""

    fin = sys.stdin if args.infile == "-" else open(args.infile)
    fout = sys.stdout if args.output == "-" else open(args.output, "w")
    mask = (1 << pkt_width(args.xlen)) - 1

    n = 0
    for lineno, line in enumerate(fin, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            rec = int(line, 16) & mask
        except ValueError:
            sys.stderr.write("[spike_trace_decode] line %d: skipping non-hex input: %r\n"
                             % (lineno, line))
            continue
        f = unpack(rec, args.xlen)
        if f["ex_valid"]:
            if args.exceptions:
                cause = f["cause"]
                # MSB set => interrupt in RISC-V mcause encoding.
                if cause >> (args.xlen - 1):
                    name = "Interrupt %d" % (cause & ((1 << (args.xlen - 1)) - 1))
                else:
                    name = CAUSE_STR.get(cause, "Exception %d" % cause)
                fout.write("# Exception PC: 0x%0*x Cause: %s tval: 0x%0*x\n"
                           % (args.xlen // 4, f["pc"], name, args.xlen // 4, f["tval"]))
            continue
        # The sim tracer only writes a commit-log line when NOT in debug mode
        # (instr_tracer.sv:195 guards on `!debug_mode`). Match that here so the
        # two commit logs stay identical when the core single-steps in debug.
        if f["debug"]:
            continue
        fout.write(spike_commit_log(f, prefix) + "\n")
        n += 1

    if fin is not sys.stdin:
        fin.close()
    if fout is not sys.stdout:
        fout.close()
    sys.stderr.write("[spike_trace_decode] decoded %d retired instructions\n" % n)


if __name__ == "__main__":
    main()
