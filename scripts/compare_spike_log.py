#!/usr/bin/env python3
# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# compare_spike_log.py
#
# Strip Spike's disassembly "trace" lines from a `spike --log-commits` log,
# keep only the commit lines, and compare them against the commit log printed
# by our synthesizable tracer (trace_hart_0_commit.synth.log, or the output of
# spike_trace_decode.py).
#
# Spike --log-commits emits, per instruction, up to two line kinds:
#   trace / disasm :  core   0: 0x0000000080000000 (0x00000297) auipc t0, ...
#   commit         :  core   0: 3 0x0000000080000000 (0x00000297) x 5 0x...0000
# The disasm line has NO privilege digit before "0x<pc>"; the commit line does
# (and carries the register/mem/csr state changes). This tool drops the disasm
# lines, strips the "core N:" prefix, and diffs the commit lines against our log
# (which uses the same `<priv> 0x<pc> (0x<insn>) <state-changes>` format, with no
# "core N:" prefix).
#
# Usage:
#   compare_spike_log.py SPIKE_LOG OUR_LOG [options]
#   compare_spike_log.py SPIKE_LOG --extract-only -o spike_commits.log
#
# By default it also drops boot-ROM commits (PC < --ram-base, default 0x80000000,
# e.g. the ROM at 0x10000000) so only RAM-region execution is compared; pass
# --no-ram-filter to keep them. Other options tolerate the documented divergences
# of the non-invasive tracer (e.g. --ignore-csr-val for WARL CSRs).

import argparse
import re
import sys

# Matches a commit line with optional "core N:" prefix; requires a single
# privilege digit before "0x<pc>", which the disasm/trace lines do NOT have.
COMMIT_RE = re.compile(
    r'^\s*(?:core\s+\d+:\s+)?'
    r'(?P<priv>\d)\s+0x(?P<pc>[0-9a-fA-F]+)\s+\(0x(?P<insn>[0-9a-fA-F]+)\)'
    r'(?P<rest>.*)$')


def extract_commits(path):
    """Return the list of (priv, pc_int, insn_str, rest_str) commit lines,
    dropping every non-commit (disasm / symbol / exception) line."""
    out = []
    with (sys.stdin if path == "-" else open(path)) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = COMMIT_RE.match(line)
            if not m:
                continue                      # <-- this drops the trace/disasm lines
            out.append((int(m["priv"]), int(m["pc"], 16),
                        m["insn"].lower(), m["rest"]))
    return out


def canon(rec, opts):
    """Canonical comparable string for one commit record."""
    priv, pc, insn, rest = rec
    r = " ".join(rest.split()).lower()        # collapse whitespace
    if opts.ignore_csr_name:                  # c769_misa -> c769
        r = re.sub(r'(\bc\d+)_\w+', r'\1', r)
    if opts.ignore_csr_val:                    # WARL CSRs: blank the value
        r = re.sub(r'(\bc\d+(?:_\w+)?\s+0x)[0-9a-f]+', r'\1WARL', r)
    if opts.no_csr:
        r = " ".join(re.sub(r'\bc\d+(?:_\w+)?\s+0x[0-9a-f]+', '', r).split())
    if opts.no_mem:
        r = " ".join(re.sub(r'\bmem\s+0x[0-9a-f]+\s+0x[0-9a-f]+', '', r).split())
    return ("%d 0x%016x (0x%s) %s" % (priv, pc, insn, r)).rstrip()


def trim_to_pc(recs, pc):
    if pc is None:
        return recs
    for i, r in enumerate(recs):
        if r[1] == pc:
            return recs[i:]
    return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("spike_log", help="Spike --log-commits log ('-' for stdin)")
    ap.add_argument("our_log", nargs="?", help="our tracer commit log (omit with --extract-only)")
    ap.add_argument("--extract-only", action="store_true",
                    help="only strip the trace lines from SPIKE_LOG and print the commit lines")
    ap.add_argument("-o", "--output", default="-", help="output file for --extract-only ('-'=stdout)")
    ap.add_argument("--keep-core", action="store_true",
                    help="(--extract-only) keep the 'core N:' prefix in the extracted lines")
    ap.add_argument("--ram-base", default="0x80000000",
                    help="RAM base; drop every commit below it (the boot ROM, e.g. 0x10000000) so "
                         "only RAM-region execution is compared. Default 0x80000000.")
    ap.add_argument("--no-ram-filter", action="store_true",
                    help="do NOT drop boot-ROM lines (compare everything, including PC<ram-base)")
    ap.add_argument("--start-pc", default=None,
                    help="align: drop leading commits until this PC on BOTH logs (e.g. 0x80000000)")
    ap.add_argument("--max-diffs", type=int, default=20, help="how many mismatches to print")
    ap.add_argument("--ignore-csr-val", action="store_true",
                    help="ignore CSR written values (WARL CSRs differ from Spike's post-WARL value)")
    ap.add_argument("--ignore-csr-name", action="store_true", help="compare CSR by number only (drop _name)")
    ap.add_argument("--no-csr", action="store_true", help="ignore CSR write tokens entirely")
    ap.add_argument("--no-mem", action="store_true", help="ignore mem tokens entirely")
    args = ap.parse_args()
    start_pc = int(args.start_pc, 16) if args.start_pc else None
    ram_base = None if args.no_ram_filter else int(args.ram_base, 16)

    # drop boot-ROM commits (PC < ram_base) so only RAM-region execution remains
    def ram_filter(recs):
        return recs if ram_base is None else [r for r in recs if r[1] >= ram_base]

    spike = trim_to_pc(ram_filter(extract_commits(args.spike_log)), start_pc)

    # --- mode 1: just delete the trace lines, print the commit lines ----------
    if args.extract_only:
        fout = sys.stdout if args.output == "-" else open(args.output, "w")
        for priv, pc, insn, rest in spike:
            pre = "core   0: " if args.keep_core else ""
            fout.write("%s%d 0x%016x (0x%s)%s\n" % (pre, priv, pc, insn, rest.rstrip()))
        if fout is not sys.stdout:
            fout.close()
        sys.stderr.write("[compare_spike_log] extracted %d commit lines "
                         "(trace lines%s dropped)\n"
                         % (len(spike), "" if ram_base is None else " + boot ROM PC<0x%x" % ram_base))
        return

    if not args.our_log:
        ap.error("OUR_LOG is required unless --extract-only is given")
    ours = trim_to_pc(ram_filter(extract_commits(args.our_log)), start_pc)

    # --- mode 2: compare in program order -------------------------------------
    n = min(len(spike), len(ours))
    mism = 0
    shown = 0
    for i in range(n):
        cs, co = canon(spike[i], args), canon(ours[i], args)
        if cs != co:
            mism += 1
            if shown < args.max_diffs:
                shown += 1
                print("MISMATCH @#%d (pc=0x%016x):\n  spike: %s\n  ours : %s"
                      % (i, spike[i][1], cs, co))
    print("\n==== summary ====")
    print("spike commit lines (trace dropped): %d" % len(spike))
    print("our   commit lines                : %d" % len(ours))
    print("compared (in order)               : %d" % n)
    print("matched                           : %d" % (n - mism))
    print("mismatched                        : %d" % mism)
    if len(spike) != len(ours):
        print("LENGTH DIFFERS by %d (alignment? use --start-pc, or check trailing instrs)"
              % abs(len(spike) - len(ours)))
    ok = (mism == 0 and len(spike) == len(ours))
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
