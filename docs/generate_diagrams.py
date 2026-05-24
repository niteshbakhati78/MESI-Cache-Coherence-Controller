"""
generate_diagrams.py
Generates two PNGs for the MESI Cache Coherence Controller docs:
  - diagrams/architecture.png   — system block diagram
  - diagrams/mesi_fsm.png       — MESI state transition diagram

Run from the repo root:
    python docs/generate_diagrams.py
"""

import math
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

OUT_DIR = os.path.join(os.path.dirname(__file__), "diagrams")
os.makedirs(OUT_DIR, exist_ok=True)

BG = "#0d1b2a"


# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────────

def arc_label_pos(x0, y0, x1, y1, rad, perp_extra=0.0, para_extra=0.0):
    """
    Label position = midpoint of the arc3 bezier at t=0.5, then shifted
    perp_extra along the perpendicular and para_extra along the chord.
    Bezier mid:  ((x0+x1)/2 + 0.5*rad*(-dy),  (y0+y1)/2 + 0.5*rad*dx)
    """
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy) or 1e-9
    lx = (x0 + x1) / 2.0 + 0.5 * rad * (-dy)
    ly = (y0 + y1) / 2.0 + 0.5 * rad * dx
    px, py = -dy / length, dx / length   # unit perpendicular
    qx, qy =  dx / length, dy / length   # unit parallel
    lx += perp_extra * px + para_extra * qx
    ly += perp_extra * py + para_extra * qy
    return lx, ly


def draw_arrow(ax, x0, y0, x1, y1, rad=0.0,
               color="#4a90d9", lw=1.7,
               label="", perp=0.3, para=0.0, fontsize=8.0):
    ax.annotate(
        "", xy=(x1, y1), xytext=(x0, y0),
        arrowprops=dict(
            arrowstyle="-|>", color=color, lw=lw, mutation_scale=14,
            connectionstyle=f"arc3,rad={rad}",
        ),
        zorder=4,
    )
    if label:
        lx, ly = arc_label_pos(x0, y0, x1, y1, rad, perp, para)
        ax.text(lx, ly, label, ha="center", va="center",
                fontsize=fontsize, color="#ddeeff",
                bbox=dict(fc=BG, ec="none", pad=2.0,
                          boxstyle="round,pad=0.25"),
                zorder=6)


def ep(src, angle_deg, dst, R):
    """Edge point on a circle of radius R at src, aimed toward dst + angle_deg twist."""
    base = math.atan2(dst[1] - src[1], dst[0] - src[0])
    a = base + math.radians(angle_deg)
    return src[0] + R * math.cos(a), src[1] + R * math.sin(a)


# ─────────────────────────────────────────────────────────────────────────────
# 1. Architecture diagram
# ─────────────────────────────────────────────────────────────────────────────

def fancy_block(ax, x, y, w, h, title, subtitle=None,
                fc="#1e3a5f", ec="#4a90d9", lw=1.5,
                title_size=11, sub_size=8.0):
    box = FancyBboxPatch(
        (x - w / 2, y - h / 2), w, h,
        boxstyle="round,pad=0,rounding_size=0.05",
        facecolor=fc, edgecolor=ec, linewidth=lw, zorder=3)
    ax.add_patch(box)
    ty = y if subtitle is None else y + h * 0.14
    ax.text(x, ty, title, ha="center", va="center",
            fontsize=title_size, fontweight="bold", color="white", zorder=4)
    if subtitle:
        ax.text(x, y - h * 0.17, subtitle, ha="center", va="center",
                fontsize=sub_size, color="#aad4f5", zorder=4)


def bidir_arrow(ax, x0, y0, x1, y1, color="#4a90d9", lw=1.6):
    ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                arrowprops=dict(arrowstyle="<|-|>", color=color,
                                lw=lw, mutation_scale=14), zorder=5)


def side_label(ax, x, y, text, ha="left", color="#99bbcc", fontsize=8.0):
    ax.text(x, y, text, ha=ha, va="center", fontsize=fontsize, color=color,
            bbox=dict(fc=BG, ec="none", pad=1.5), zorder=6)


def make_architecture():
    fig, ax = plt.subplots(figsize=(12, 8))
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)
    ax.set_xlim(0, 12)
    ax.set_ylim(0, 8)
    ax.axis("off")

    ax.text(6, 7.7, "MESI Cache Coherence Controller — System Architecture",
            ha="center", va="center", fontsize=14, fontweight="bold",
            color="white")

    # Core 0
    ax.add_patch(FancyBboxPatch((0.3, 3.6), 4.2, 3.6,
                                boxstyle="round,pad=0,rounding_size=0.1",
                                facecolor="#0e1f33", edgecolor="#1f4477",
                                linewidth=1.2, zorder=1))
    ax.text(2.4, 7.05, "CPU Core 0", ha="center", fontsize=9,
            color="#6699cc", style="italic")
    fancy_block(ax, 2.4, 6.0, 3.6, 0.8,
                "L1 Cache Controller 0",
                subtitle="2-way set-assoc  ·  write-back  ·  MESI FSM",
                fc="#1a3a5c", ec="#3a7abf", title_size=10, sub_size=7.5)
    for xi, lbl in zip([1.2, 2.4, 3.6],
                        ["MESI FSM", "Cache RAM\n(Data+Tag)", "LRU\nReplacer"]):
        ax.add_patch(FancyBboxPatch((xi - 0.54, 3.78), 1.08, 0.62,
                                   boxstyle="round,pad=0,rounding_size=0.03",
                                   facecolor="#0f2840", edgecolor="#2a5080",
                                   linewidth=1, zorder=2))
        ax.text(xi, 4.09, lbl, ha="center", va="center",
                fontsize=6.5, color="#99bbdd")

    # Core 1
    ax.add_patch(FancyBboxPatch((7.5, 3.6), 4.2, 3.6,
                                boxstyle="round,pad=0,rounding_size=0.1",
                                facecolor="#0e1f33", edgecolor="#1f4477",
                                linewidth=1.2, zorder=1))
    ax.text(9.6, 7.05, "CPU Core 1", ha="center", fontsize=9,
            color="#6699cc", style="italic")
    fancy_block(ax, 9.6, 6.0, 3.6, 0.8,
                "L1 Cache Controller 1",
                subtitle="2-way set-assoc  ·  write-back  ·  MESI FSM",
                fc="#1a3a5c", ec="#3a7abf", title_size=10, sub_size=7.5)
    for xi, lbl in zip([8.4, 9.6, 10.8],
                        ["MESI FSM", "Cache RAM\n(Data+Tag)", "LRU\nReplacer"]):
        ax.add_patch(FancyBboxPatch((xi - 0.54, 3.78), 1.08, 0.62,
                                   boxstyle="round,pad=0,rounding_size=0.03",
                                   facecolor="#0f2840", edgecolor="#2a5080",
                                   linewidth=1, zorder=2))
        ax.text(xi, 4.09, lbl, ha="center", va="center",
                fontsize=6.5, color="#99bbdd")

    # Bus arbiter & L2
    fancy_block(ax, 6.0, 2.3, 5.2, 0.85,
                "Snooping Bus Arbiter",
                subtitle="Round-robin arbitration  ·  Snoop broadcast  ·  Dirty intervention",
                fc="#1a2a0a", ec="#6aaa20", title_size=11, sub_size=7.5)
    fancy_block(ax, 6.0, 0.9, 4.4, 0.8,
                "Shared L2 Cache",
                subtitle="Inclusive  ·  Write-back SRAM  ·  256 lines",
                fc="#2a1a0a", ec="#cc7722", title_size=11, sub_size=7.5)

    # Arrows — labels placed to the SIDE, not on the line
    bidir_arrow(ax, 2.4, 3.6, 3.6, 2.73, color="#4a90d9")
    side_label(ax, 3.72, 3.17, "req / gnt\nsnoop / ack", ha="left")

    bidir_arrow(ax, 9.6, 3.6, 8.4, 2.73, color="#4a90d9")
    side_label(ax, 8.28, 3.17, "req / gnt\nsnoop / ack", ha="right")

    bidir_arrow(ax, 6.0, 1.875, 6.0, 1.3, color="#cc7722")
    side_label(ax, 6.12, 1.58, "rd / wr  ·  data", ha="left")

    ax.plot([3.6, 8.4], [2.73, 2.73],
            color="#4a90d9", lw=0.8, ls="--", alpha=0.35, zorder=2)

    ax.legend(handles=[
        mpatches.Patch(facecolor="#1a3a5c", edgecolor="#3a7abf",
                       label="L1 Cache Controller (MESI FSM)"),
        mpatches.Patch(facecolor="#1a2a0a", edgecolor="#6aaa20",
                       label="Snooping Bus Arbiter"),
        mpatches.Patch(facecolor="#2a1a0a", edgecolor="#cc7722",
                       label="Shared L2 Cache"),
    ], loc="lower left", fontsize=9, facecolor=BG, edgecolor="#334455",
              labelcolor="white", framealpha=0.95)

    fig.tight_layout(pad=0.3)
    out = os.path.join(OUT_DIR, "architecture.png")
    fig.savefig(out, dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"Saved {out}")


# ─────────────────────────────────────────────────────────────────────────────
# 2. MESI state transition diagram
#
# Diamond layout:  I (top)  E (left)  S (right)  M (bottom)
#
# With large node spacing (16×12 canvas), each transition has room for
# its label.  The only structural crossing is I↔M (vertical) vs E→S
# (horizontal) — separated by color and aggressive arc curvature.
# ─────────────────────────────────────────────────────────────────────────────

def make_mesi_fsm():
    # Diamond layout: I top, E left, S right, M bottom.
    # All transition labels are placed at explicit hardcoded positions
    # around the outside of the diamond to avoid center overlap.
    fig, ax = plt.subplots(figsize=(16, 12))
    fig.patch.set_facecolor(BG)
    ax.set_facecolor(BG)
    ax.set_xlim(-3.0, 19.0)
    ax.set_ylim(-1.8, 12.5)
    ax.axis("off")

    ax.text(8.0, 12.1, "MESI Protocol — State Transition Diagram",
            ha="center", va="center", fontsize=15, fontweight="bold",
            color="white")

    # ── Node positions ─────────────────────────────────────────────────
    NI = (8.0, 10.5)   # Invalid   — top
    NE = (2.0,  5.5)   # Exclusive — left
    NS = (14.0, 5.5)   # Shared    — right
    NM = (8.0,  0.5)   # Modified  — bottom
    R  = 0.85

    def state_node(pos, letter, name, fc, ec):
        ax.add_patch(plt.Circle(pos, R, facecolor=fc, edgecolor=ec,
                                linewidth=2.8, zorder=3))
        ax.text(pos[0], pos[1] + 0.06, letter, ha="center", va="center",
                fontsize=32, fontweight="bold", color="white", zorder=4)
        ax.text(pos[0], pos[1] - R - 0.32, name, ha="center", va="top",
                fontsize=10, color="#aabbcc", zorder=4)

    state_node(NI, "I", "Invalid",   "#252525", "#888888")
    state_node(NE, "E", "Exclusive", "#0f4f1a", "#3daa55")
    state_node(NS, "S", "Shared",    "#0f2f5a", "#3a7abf")
    state_node(NM, "M", "Modified",  "#7b1010", "#e05555")

    C_PROC = "#4dcc70"   # green  — processor-initiated
    C_BUS  = "#5599ee"   # blue   — bus snoop
    C_WB   = "#dd8833"   # orange — writeback

    def lbl(ax, x, y, text, ha="center", fontsize=8.0):
        """Standalone label box at an explicit position."""
        ax.text(x, y, text, ha=ha, va="center",
                fontsize=fontsize, color="#ddeeff",
                bbox=dict(fc=BG, ec="none", pad=2.5,
                          boxstyle="round,pad=0.3"),
                zorder=7)

    # ════════════════════════════════════════════════════════════════════
    # I ↔ E  (left diagonal)
    # I→E arcs to the OUTSIDE (upper-left); E→I arcs to the INSIDE.
    # Achieved by offsetting start/end angles ±20° from the chord direction.
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NI, +20, NE, R);  p1 = ep(NE, -20, NI, R)
    draw_arrow(ax, *p0, *p1, rad=-0.35, color=C_PROC)   # I→E, bows outside
    lbl(ax, -1.5, 9.0, "PrRd / BusRd → E\n(no sharer)", ha="left")

    p0 = ep(NE, +20, NI, R);  p1 = ep(NI, -20, NE, R)
    draw_arrow(ax, *p0, *p1, rad=+0.20, color=C_BUS)    # E→I, bows inside
    lbl(ax, 4.5, 8.2, "BusRdX/Upgr snoop → I")

    # ════════════════════════════════════════════════════════════════════
    # I ↔ S  (right diagonal, mirror of I↔E)
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NI, -20, NS, R);  p1 = ep(NS, +20, NI, R)
    draw_arrow(ax, *p0, *p1, rad=+0.35, color=C_PROC)   # I→S, bows outside
    lbl(ax, 17.5, 9.0, "PrRd / BusRd → S\n(sharer exists)", ha="right")

    p0 = ep(NS, -20, NI, R);  p1 = ep(NI, +20, NS, R)
    draw_arrow(ax, *p0, *p1, rad=-0.20, color=C_BUS)    # S→I, bows inside
    lbl(ax, 11.5, 8.2, "BusRdX/Upgr snoop → I")

    # ════════════════════════════════════════════════════════════════════
    # I ↔ M  (vertical): arced FAR right / FAR left to clear the center
    # Start/end points are on the east/west flanks of each node.
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NI, +90, NM, R);  p1 = ep(NM, -90, NI, R)  # both on east side
    draw_arrow(ax, *p0, *p1, rad=+0.55, color=C_PROC)   # I→M, sweeps right
    lbl(ax, 17.5, 5.5, "PrWr / BusRdX → M\n(write miss)", ha="right")

    p0 = ep(NM, +90, NI, R);  p1 = ep(NI, -90, NM, R)  # both on west side
    draw_arrow(ax, *p0, *p1, rad=+0.55, color=C_WB)     # M→I, sweeps left
    lbl(ax, -1.5, 5.5, "Evict / BusWB → I\nBusRdX snoop → WB+I", ha="left")

    # ════════════════════════════════════════════════════════════════════
    # E → S  (horizontal, one direction only — BusRd snoop downgrade)
    # Straight horizontal arrow at mid-height of E and S.
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NE, 0, NS, R)      # east side of E
    p1 = ep(NS, 0, NE, R)      # west side of S (i.e. ep with 0° offset = directly toward NE)
    draw_arrow(ax, *p0, *p1, rad=+0.0, color=C_BUS)
    lbl(ax, 8.0, 5.5, "BusRd snoop → S (E→S downgrade)")

    # ════════════════════════════════════════════════════════════════════
    # E → M  (left-bottom diagonal, outside the diamond)
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NE, -30, NM, R);  p1 = ep(NM, +150, NE, R)
    draw_arrow(ax, *p0, *p1, rad=-0.25, color=C_PROC)
    lbl(ax, -1.5, 2.5, "PrWr / — → M\n(silent upgrade)", ha="left")

    # ════════════════════════════════════════════════════════════════════
    # S ↔ M  (right-bottom diagonal)
    # S→M arcs outside (to the right); M→S arcs inside.
    # ════════════════════════════════════════════════════════════════════
    p0 = ep(NS, -30, NM, R);  p1 = ep(NM, +150, NS, R)
    draw_arrow(ax, *p0, *p1, rad=+0.25, color=C_PROC)   # S→M, outside right
    lbl(ax, 17.5, 2.5, "PrWr / BusUpgr → M", ha="right")

    p0 = ep(NM, -30, NS, R);  p1 = ep(NS, +150, NM, R)
    draw_arrow(ax, *p0, *p1, rad=+0.25, color=C_WB)     # M→S, inside
    lbl(ax, 12.5, 2.0, "BusRd snoop\n→ WB + S")

    # ── Legends ───────────────────────────────────────────────────────────
    leg1 = ax.legend(handles=[
        mpatches.Patch(facecolor="#7b1010", edgecolor="#e05555", label="Modified (M)"),
        mpatches.Patch(facecolor="#0f4f1a", edgecolor="#3daa55", label="Exclusive (E)"),
        mpatches.Patch(facecolor="#0f2f5a", edgecolor="#3a7abf", label="Shared (S)"),
        mpatches.Patch(facecolor="#252525", edgecolor="#888888", label="Invalid (I)"),
    ], loc="lower left", fontsize=9.5, facecolor=BG, edgecolor="#334455",
              labelcolor="white", framealpha=0.95,
              title="States", title_fontsize=10)
    leg1.get_title().set_color("white")
    ax.add_artist(leg1)

    leg2 = ax.legend(handles=[
        mpatches.Patch(color=C_PROC, label="Processor-initiated"),
        mpatches.Patch(color=C_BUS,  label="Bus snoop (other cache)"),
        mpatches.Patch(color=C_WB,   label="Writeback to L2"),
    ], loc="lower right", fontsize=9.5, facecolor=BG, edgecolor="#334455",
              labelcolor="white", framealpha=0.95,
              title="Arrow colors", title_fontsize=10)
    leg2.get_title().set_color("white")

    ax.text(8.0, -1.2, "Format:  Trigger / BusOp → NewState",
            ha="center", va="bottom", fontsize=8.5, color="#556677",
            style="italic")

    fig.tight_layout(pad=0.3)
    out = os.path.join(OUT_DIR, "mesi_fsm.png")
    fig.savefig(out, dpi=180, facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"Saved {out}")


# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    make_architecture()
    make_mesi_fsm()
    print("Done. Images written to docs/diagrams/")
