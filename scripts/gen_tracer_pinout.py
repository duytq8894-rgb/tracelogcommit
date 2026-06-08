#!/usr/bin/env python3
# Render a large "chip pinout" image of instr_tracer_synth with every input /
# output pin described, grouped by function.
#
#   python3 scripts/gen_tracer_pinout.py
#
# Output: hardware/src/trace/instr_tracer_synth_pinout.png

import os
from PIL import Image, ImageDraw, ImageFont

FONT_DIR = "/usr/share/fonts/dejavu"
def F(name, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)

f_title = F("DejaVuSans-Bold.ttf", 32)
f_sub   = F("DejaVuSans.ttf", 17)
f_mod   = F("DejaVuSans-Bold.ttf", 27)
f_mods  = F("DejaVuSans.ttf", 15)
f_hdr   = F("DejaVuSans-Bold.ttf", 16)
f_pin   = F("DejaVuSansMono-Bold.ttf", 16)
f_wid   = F("DejaVuSansMono.ttf", 13)
f_desc  = F("DejaVuSans.ttf", 14)
f_dir   = F("DejaVuSans-Bold.ttf", 12)

# ----------------------------------------------------------------- colours
NAVY  = (31, 58, 95)
WHITE = (255, 255, 255)
GREY  = (120, 120, 120)
DESC  = (55, 55, 55)
BOXF  = (248, 250, 253)

CTRL  = ((90, 90, 90),    (236, 236, 236))
BLUE  = ((46, 109, 180),  (224, 236, 250))
PURP  = ((120, 70, 160),  (238, 230, 247))
ORNG  = ((196, 118, 28),  (252, 238, 220))
GREEN = ((52, 134, 66),   (222, 240, 224))

# ----------------------------------------------------------------- pin data
# (name, width/type, description, direction)   direction: 'in' | 'out'
left_groups = [
    ("CLOCK / RESET / CONTROL", CTRL, [
        ("clk_i",        "[1]",          "clock",                                          "in"),
        ("rst_ni",       "[1]",          "asynchronous active-low reset",                  "in"),
        ("flush_i",      "[1]",          "drop all buffered trace (clear trace FIFO)",     "in"),
        ("testmode_i",   "[1]",          "DFT: bypass the FIFO clock-gate",                "in"),
    ]),
    ("COMMIT-STAGE OBSERVATION  (per cycle, 2 commit ports)", BLUE, [
        ("commit_instr_i", "[1:0] sbe",  "retiring instr(s): pc, rd, op, fu, is_compressed", "in"),
        ("commit_ack_i",   "[1:0]",      "port retires this cycle (gates a commit-log line)", "in"),
        ("instr_word_i",   "[1:0][31:0]","raw (RVC-able) instr word  ( = ex.tval[31:0] )", "in"),
        ("waddr_i",        "[1:0][4:0]", "write-back register index",                      "in"),
        ("wdata_i",        "[1:0][XLEN]","write-back data",                                "in"),
        ("we_gpr_i",       "[1:0]",      "GPR write-enable",                               "in"),
        ("we_fpr_i",       "[1:0]",      "FPR write-enable",                               "in"),
        ("priv_lvl_i",     "[1:0]",      "privilege level  (M=3, S=1, U=0)",               "in"),
        ("debug_mode_i",   "[1]",        "core in debug mode (suppresses the log line)",   "in"),
        ("exception_i",    "exc_t",      "exception / interrupt  {valid, cause, tval}",    "in"),
    ]),
    ("CSR WRITE OBSERVATION  (in-order on port 0)", PURP, [
        ("csr_commit_i",   "[1]",        "a CSR instruction committed",                    "in"),
        ("csr_op_i",       "fu_op",      "CSR op: WRITE / SET / CLEAR / read",             "in"),
        ("csr_waddr_i",    "[11:0]",     "CSR address",                                    "in"),
        ("csr_operand_i",  "[XLEN]",     "operand (rs1 / zimm)",                           "in"),
        ("csr_old_i",      "[XLEN]",     "pre-write CSR value (csr_rdata_o)",              "in"),
    ]),
    ("LSU MEMORY-ACCESS OBSERVATION", ORNG, [
        ("st_valid_i",     "[1]",        "store buffer accepted a store (push store FIFO)", "in"),
        ("st_paddr_i",     "[PLEN]",     "store physical address",                         "in"),
        ("st_data_i",      "[XLEN]",     "store data (after CVA6 data_align rotate)",      "in"),
        ("st_size_i",      "[1:0]",      "store size  0=B 1=H 2=W 3=D",                    "in"),
        ("ld_valid_i",     "[1]",        "load address generated (push load FIFO)",        "in"),
        ("ld_kill_i",      "[1]",        "load was killed -> do not track",                "in"),
        ("ld_paddr_i",     "[PLEN]",     "load physical address",                          "in"),
        ("ld_size_i",      "[1:0]",      "load size  0=B 1=H 2=W 3=D",                     "in"),
        ("flush_addr_i",   "[1]",        "pipeline flush -> drop pending addr mappings",   "in"),
    ]),
]

right_group = ("STREAMING TRACE-OUT  (ready / valid handshake)", GREEN, [
    ("trace_valid_o", "[1]",    "a buffered beat is available",                       "out"),
    ("trace_beat_o",  "beat_t", "packed beat: valid[2] + 2x commit_log_pkt_t",        "out"),
    ("trace_ready_i", "[1]",    "consumer accepts the beat (back-pressure)",          "in"),
    ("overflow_o",    "[1]",    "beat dropped / addr-FIFO misaligned -> not gap-free","out"),
])

# ----------------------------------------------------------------- geometry
W        = 1820
XBOX_L   = 720
XBOX_R   = 1200
BOX_TOP  = 158
PIN_DY   = 44
HDR_H    = 30
GRP_GAP  = 20
PINS_TOP = BOX_TOP + 118

# measure left-group total height to size the canvas
def left_height():
    y = PINS_TOP
    for _, _, pins in left_groups:
        y += HDR_H + 10
        y += PIN_DY * len(pins)
        y += GRP_GAP
    return y

BOX_BOT = left_height() + 18
H = BOX_BOT + 70

img = Image.new("RGB", (W, H), WHITE)
d = ImageDraw.Draw(img)

def arrow_in_left(x, y, c):           # points right, into box at x
    d.line([(x - 30, y), (x - 9, y)], fill=c, width=2)
    d.polygon([(x, y), (x - 10, y - 5), (x - 10, y + 5)], fill=c)

def arrow_out_right(x, y, c):         # points right, out of box at x (+30)
    d.line([(x, y), (x + 21, y)], fill=c, width=2)
    d.polygon([(x + 30, y), (x + 20, y - 5), (x + 20, y + 5)], fill=c)

def arrow_in_right(x, y, c):          # points left, into box at x
    d.line([(x + 30, y), (x + 9, y)], fill=c, width=2)
    d.polygon([(x, y), (x + 10, y - 5), (x + 10, y + 5)], fill=c)

# ----- title
d.text((W / 2, 40), "instr_tracer_synth  —  module pinout",
       font=f_title, fill=NAVY, anchor="mm")
d.text((W / 2, 78),
       "synthesizable commit tracer for CVA6  ·  every input / output pin",
       font=f_sub, fill=GREY, anchor="mm")

# ----- module box
d.rounded_rectangle([XBOX_L, BOX_TOP, XBOX_R, BOX_BOT], radius=14,
                    fill=BOXF, outline=NAVY, width=3)
cx = (XBOX_L + XBOX_R) / 2
d.text((cx, BOX_TOP + 34), "instr_tracer_synth", font=f_mod, fill=NAVY, anchor="mm")
d.text((cx, BOX_TOP + 64), "param  FifoDepth = 32", font=f_mods, fill=GREY, anchor="mm")
d.text((cx, BOX_TOP + 88), "capture -> pack -> FIFO -> stream", font=f_mods, fill=(110,130,160), anchor="mm")
d.text((cx, BOX_BOT - 26),
       "always_ff + always_comb only", font=f_mods, fill=(150,160,175), anchor="mm")

# ----- left pins
y = PINS_TOP
for title, (dark, tint), pins in left_groups:
    d.rounded_rectangle([150, y, XBOX_L - 36, y + HDR_H], radius=6, fill=tint)
    d.text((164, y + HDR_H / 2), title, font=f_hdr, fill=dark, anchor="lm")
    y += HDR_H + 10
    for name, wid, desc, _ in pins:
        arrow_in_left(XBOX_L, y, dark)
        nm_x = XBOX_L + 14
        d.text((nm_x, y), name, font=f_pin, fill=dark, anchor="lm")
        nlen = d.textlength(name, font=f_pin)
        d.text((nm_x + nlen + 8, y), wid, font=f_wid, fill=GREY, anchor="lm")
        d.text((XBOX_L - 42, y), desc, font=f_desc, fill=DESC, anchor="rm")
        y += PIN_DY
    y += GRP_GAP

# ----- right pins (vertically centred)
title, (dark, tint), pins = right_group
grp_h = HDR_H + 10 + PIN_DY * len(pins)
ry = (BOX_TOP + BOX_BOT) / 2 - grp_h / 2
d.rounded_rectangle([XBOX_R + 36, ry, W - 40, ry + HDR_H], radius=6, fill=tint)
d.text((XBOX_R + 50, ry + HDR_H / 2), title, font=f_hdr, fill=dark, anchor="lm")
ry += HDR_H + 10
for name, wid, desc, direction in pins:
    if direction == "out":
        arrow_out_right(XBOX_R, ry, dark); tag, tagc = "out", dark
    else:
        arrow_in_right(XBOX_R, ry, dark);  tag, tagc = "in", (196, 118, 28)
    nm_x = XBOX_R - 14
    d.text((nm_x, ry), name, font=f_pin, fill=dark, anchor="rm")
    nlen = d.textlength(name, font=f_pin)
    d.text((nm_x - nlen - 8, ry), wid, font=f_wid, fill=GREY, anchor="rm")
    d.text((XBOX_R + 44, ry), desc, font=f_desc, fill=DESC, anchor="lm")
    # direction badge at far right edge of the stub
    d.text((XBOX_R + 44, ry - 16), tag, font=f_dir, fill=tagc, anchor="lm")
    ry += PIN_DY

# ----- footer legend
ly = H - 34
d.text((150, ly), "→ arrow into the box = input        arrow out = output        "
                  "[w] = bit width   ·   sbe = scoreboard_entry_t  ·  exc_t = exception_t  "
                  "·  beat_t = commit_log_beat_t",
       font=f_desc, fill=GREY, anchor="lm")

out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "hardware", "src", "trace")
out = os.path.join(out_dir, "instr_tracer_synth_pinout.png")
img.save(out)
print("wrote", out, "size", img.size)
