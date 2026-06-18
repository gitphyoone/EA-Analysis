"""
V19 FX Prop Desk — Hierarchical Architecture Chart
Generates: D:\PJ\EA\V19_EA_Architecture.pdf
Run: python generate_chart.py
"""
import sys
import subprocess

# Auto-install matplotlib if missing
try:
    import matplotlib
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "matplotlib"])
    import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
from matplotlib.backends.backend_pdf import PdfPages

# ── Palette ──────────────────────────────────────────────────────────
C = {
    "mt4":    "#1565C0", "mt4_bg":   "#DCEEFB",
    "api":    "#2E7D32", "api_bg":   "#E8F5E9",
    "eng":    "#6A1B9A", "eng_bg":   "#F3E5F5",
    "db":     "#BF360C", "db_bg":    "#FBE9E7",
    "dash":   "#00695C", "dash_bg":  "#E0F2F1",
    "conn":   "#546E7A",
    "fg":     "#212121", "sub":      "#546E7A",
    "white":  "#FFFFFF", "bg":       "#F8FAFB",
}

# ── Helpers ───────────────────────────────────────────────────────────
def box(ax, x, y, w, h, title, items, bg, border, title_color="white",
        title_fs=8, item_fs=6.3, phase=None):
    """Rounded box with coloured header and bullet list."""
    # Shadow
    ax.add_patch(FancyBboxPatch((x+0.04, y-0.04), w, h,
        boxstyle="round,pad=0.015", facecolor="#C0C0C0",
        edgecolor="none", linewidth=0, zorder=1))
    # Body
    ax.add_patch(FancyBboxPatch((x, y), w, h,
        boxstyle="round,pad=0.015", facecolor=bg,
        edgecolor=border, linewidth=1.6, zorder=2))
    # Header bar
    hh = h * 0.26
    ax.add_patch(FancyBboxPatch((x, y+h-hh), w, hh,
        boxstyle="round,pad=0.010", facecolor=border,
        edgecolor=border, linewidth=0, zorder=3))
    # Phase badge
    if phase:
        ax.add_patch(FancyBboxPatch((x+0.04, y+h-hh+0.025), 0.32, hh-0.05,
            boxstyle="round,pad=0.005", facecolor="white",
            edgecolor="none", linewidth=0, zorder=4, alpha=0.85))
        ax.text(x+0.20, y+h-hh/2, phase,
                ha="center", va="center", fontsize=5.5,
                fontweight="bold", color=border, zorder=5)
        tx = x + w/2 + 0.10
    else:
        tx = x + w/2
    ax.text(tx, y+h-hh/2, title,
            ha="center", va="center", fontsize=title_fs,
            fontweight="bold", color=title_color, zorder=4)
    # Items
    if items:
        usable = h - hh - 0.04
        lh = usable / max(len(items), 1)
        for i, item in enumerate(items):
            iy = y + h - hh - 0.03 - (i+0.5)*lh
            ax.text(x+0.06, iy, f"› {item}",
                    ha="left", va="center", fontsize=item_fs,
                    color=C["fg"], zorder=4, clip_on=True)

def arrow(ax, x1, y1, x2, y2, label="", lw=1.6, style="->"):
    ax.annotate("", xy=(x2, y2), xytext=(x1, y1),
                arrowprops=dict(arrowstyle=style, color=C["conn"],
                                lw=lw, connectionstyle="arc3,rad=0.0"),
                zorder=1)
    if label:
        mx, my = (x1+x2)/2+0.05, (y1+y2)/2
        ax.text(mx, my, label, fontsize=5.8, color=C["sub"],
                ha="left", va="center",
                bbox=dict(boxstyle="round,pad=0.12", facecolor="white",
                          alpha=0.85, edgecolor="none"))

def horiz_bar(ax, x1, x2, y, color, lw=1.6):
    ax.plot([x1, x2], [y, y], color=color, lw=lw, zorder=0)

def layer_label(ax, x, y, text, color):
    ax.text(x, y, text, ha="center", va="center",
            fontsize=9.5, fontweight="bold", color=color,
            bbox=dict(boxstyle="round,pad=0.18", facecolor="white",
                      edgecolor=color, linewidth=1.2))

# ── Figure — A3 landscape ────────────────────────────────────────────
FW, FH = 16.54, 11.69
fig = plt.figure(figsize=(FW, FH))
ax  = fig.add_axes([0.0, 0.0, 1.0, 1.0])
ax.set_xlim(0, FW); ax.set_ylim(0, FH)
ax.axis("off")
ax.set_facecolor(C["bg"]); fig.patch.set_facecolor(C["bg"])

# ── Page border ──────────────────────────────────────────────────────
for spine in ["left","right","top","bottom"]:
    ax.spines[spine].set_visible(False)
ax.add_patch(FancyBboxPatch((0.15, 0.12), FW-0.30, FH-0.26,
    boxstyle="round,pad=0.02", facecolor="none",
    edgecolor="#B0BEC5", linewidth=1.0, zorder=0))

# ══════════════════════════════════════════════════════════════════════
# TITLE BAND
# ══════════════════════════════════════════════════════════════════════
ax.add_patch(FancyBboxPatch((0.15, FH-1.05), FW-0.30, 0.90,
    boxstyle="round,pad=0.01", facecolor=C["mt4"],
    edgecolor="none", linewidth=0, zorder=1))
ax.text(FW/2, FH-0.58, "V19 FX PROP DESK — SYSTEM ARCHITECTURE",
        ha="center", va="center", fontsize=18, fontweight="bold",
        color="white", zorder=2)
ax.text(FW/2, FH-0.88, "Hierarchical Data Flow: MT4  →  FastAPI  →  6 Engines  →  PostgreSQL + Redis  →  Dashboard",
        ha="center", va="center", fontsize=9.5, color="#B3E5FC", zorder=2)

# ══════════════════════════════════════════════════════════════════════
# LAYER 1 — MT4 TERMINAL  (y = 8.85 … 10.6)
# ══════════════════════════════════════════════════════════════════════
L1_Y = 8.65; L1_H = 1.88

box(ax, 0.45, L1_Y, 7.5, L1_H,
    "DataCollector.mq4", [
        "Runs on H1 bar close — polls 6 symbols",
        "Collects: OHLCV + EMA50/200, RSI14, ADX14",
        "Collects: DI+(Plus), DI−(Minus), ATR14",
        "HTTP POST → FastAPI /data/candle (JSON)",
        "Timer-based: EventSetTimer(60s)",
    ],
    C["mt4_bg"], C["mt4"], item_fs=6.5)

box(ax, 8.45, L1_Y, 7.8, L1_H,
    "TradeExecutor.mq4  (v2 — all fixes applied)", [
        "CB: one-way daily latch (realized + floating loss)",
        "Queries /analytics/drawdown — not just balance delta",
        "Friday ≥20:00 UTC: CloseAll + block new entries",
        "Signal poll: /signals/evaluate/{sym}?pip_value=live",
        "Partial-close: per-ticket latch array (never fires twice)",
        "BE = entry ± 1-pip buffer; ATR trail after +2R",
        "Telegram alerts: CB / trade-open / close-all",
    ],
    C["mt4_bg"], C["mt4"], item_fs=6.5)

layer_label(ax, FW/2, L1_Y + L1_H + 0.18, "  MT4 TERMINAL  ", C["mt4"])
horiz_bar(ax, 0.45, 16.25, L1_Y + L1_H + 0.13, C["mt4"], 1.4)

# arrows MT4 → FastAPI
arrow(ax, 4.20, L1_Y, 4.80, L1_Y-0.55, "POST /data/candle")
arrow(ax, 12.35, L1_Y, 11.75, L1_Y-0.55, "GET /signals/evaluate")

# ══════════════════════════════════════════════════════════════════════
# LAYER 2 — FASTAPI BACKEND  (y = 7.05 … 8.55)
# ══════════════════════════════════════════════════════════════════════
L2_Y = 6.95; L2_H = 1.55

routers = [
    ("/data",      ["POST /candle",       "GET /candles/{sym}"]),
    ("/signals",   ["GET /evaluate/{sym}","GET /circuit-breaker"]),
    ("/trades",    ["POST /open",          "POST /close/{id}","POST /manage/{id}"]),
    ("/analytics", ["GET /performance",    "GET /drawdown","GET /equity-curve","GET /trade-history"]),
]
for i,(title,items) in enumerate(routers):
    rx = 0.55 + i*4.0
    box(ax, rx, L2_Y, 3.7, L2_H, title, items,
        C["api_bg"], C["api"], item_fs=6.3)

layer_label(ax, FW/2, L2_Y + L2_H + 0.18, "  FASTAPI BACKEND (port 8000)  ", C["api"])
horiz_bar(ax, 0.45, 16.25, L2_Y + L2_H + 0.13, C["api"], 1.4)

# arrows FastAPI → engines (single trunk)
arrow(ax, FW/2, L2_Y, FW/2, L2_Y-0.52, "evaluate / gate / read / write")

# ══════════════════════════════════════════════════════════════════════
# LAYER 3 — 6 ENGINES  (y = 3.95 … 6.25)
# ══════════════════════════════════════════════════════════════════════
L3_Y = 3.85; L3_H = 2.48

engines = [
    ("SIGNAL ENGINE",   "P1", [
        "EMA50 > EMA200 trend",
        "Regime: EMA gap ≥ 0.1%",
        "Body ≤ 1.5 × ATR guard",
        "HTF H4 bias (optional)",
        "RSI 55-70 / 30-45",
        "ADX>40 → RSI→80/20",
        "DI+ > DI− (BUY)",
        "ATR > minimum floor",
    ]),
    ("RISK ENGINE",     "P2", [
        "Risk: 0.25% equity/trade",
        "SL: ATR × 1.5",
        "TP: ATR × 3.0  (2R:1R)",
        "Live pip value from MT4",
        "Spread guard ≤ 2× avg",
        "Lot rounded to 0.01",
        "CB: 3% / 6% / 10% DD",
        "Realized + float loss",
    ]),
    ("PORTFOLIO",       "P3", [
        "Max 3 open positions",
        "Corr filter: 60-period",
        "Max corr threshold: 0.80",
        "Currency overlap removed",
        "Exposure: USD-normalised",
        "Limit: Equity × 2",
    ]),
    ("NEWS ENGINE",     "P4", [
        "TradingEconomics API",
        "Fail-safe block (default)",
        "15min cache if <2h away",
        "1hr cache otherwise",
        "HIGH impact only",
        "±30min blackout window",
    ]),
    ("SESSION ENGINE",  "P5", [
        "London  08–17 UTC",
        "New York 13–22 UTC",
        "Overlap  13–17 UTC",
        "DST-aware (pytz)",
        "Friday ≥20:00 → close",
        "Weekend detection",
    ]),
    ("TRADE MANAGER",   "P6", [
        "+1R → BE + 1pip buffer",
        "Early trail option (1R)",
        "+2R → close 50% once",
        "Per-ticket latch array",
        "+2R → ATR×1.5 trail",
        "NONE if no condition met",
    ]),
]
EW = (FW - 0.90) / 6 - 0.05
for i,(title,ph,items) in enumerate(engines):
    ex = 0.50 + i*(EW+0.07)
    box(ax, ex, L3_Y, EW, L3_H, title, items,
        C["eng_bg"], C["eng"], item_fs=5.9, phase=ph)

layer_label(ax, FW/2, L3_Y + L3_H + 0.18, "  6 BUSINESS ENGINES  ", C["eng"])
horiz_bar(ax, 0.45, 16.25, L3_Y + L3_H + 0.13, C["eng"], 1.4)

# arrows Engines → DB
arrow(ax, FW/2, L3_Y, FW/2, L3_Y-0.50, "persist trades / read indicators")

# ══════════════════════════════════════════════════════════════════════
# LAYER 4 — DATA STORE  (y = 1.85 … 3.65)
# ══════════════════════════════════════════════════════════════════════
L4_Y = 1.72; L4_H = 1.90

box(ax, 0.50, L4_Y, 7.55, L4_H,
    "PostgreSQL  (port 5432)", [
        "market_data — OHLCV + 7 indicators, symbol/TF indexed",
        "trades — open positions: entry, SL, TP, lot, session, equity",
        "trade_history — closed trades: R-multiple, net PnL, exit reason",
        "quant_journal — daily equity / DD / WR / PF / Sharpe",
        "news_events — HIGH-impact calendar cache",
        "db-backup service: daily pg_dump → ./backups/ (30-day TTL)",
    ],
    C["db_bg"], C["db"], item_fs=6.5)

box(ax, 8.50, L4_Y, 7.65, L4_H,
    "Redis  (port 6379)", [
        "news:{date} — HIGH-impact events (15min or 1hr TTL)",
        "Dynamic TTL: shorten to 15min when event < 2hrs away",
        "Circuit breaker state — persists across server restarts",
        "Fast read path for signal evaluation hot loop",
    ],
    C["db_bg"], C["db"], item_fs=6.5)

layer_label(ax, FW/2, L4_Y + L4_H + 0.18, "  DATA STORE  ", C["db"])
horiz_bar(ax, 0.45, 16.25, L4_Y + L4_H + 0.13, C["db"], 1.4)

# arrow DB → Dashboard
arrow(ax, FW/2, L4_Y, FW/2, L4_Y-0.48, "REST API (30s auto-refresh)")

# ══════════════════════════════════════════════════════════════════════
# LAYER 5 — DASHBOARD  (y = 0.32 … 1.55)
# ══════════════════════════════════════════════════════════════════════
L5_Y = 0.30; L5_H = 1.28

panels = [
    ("Equity Curve",    ["Chart.js line chart","Full account history"]),
    ("Open Positions",  ["Real-time table","Entry/SL/TP/Session"]),
    ("Daily P&L",       ["Bar chart per day","Green/red colouring"]),
    ("Performance KPIs",["Win Rate / Profit Factor","Sharpe / Expectancy"]),
    ("Drawdown",        ["Daily/Weekly/Monthly","CB threshold markers"]),
    ("Trade History",   ["All closed records","R-multiple / exit reason"]),
]
PW = (FW - 0.90) / 6 - 0.05
for i,(title,items) in enumerate(panels):
    px = 0.50 + i*(PW+0.07)
    box(ax, px, L5_Y, PW, L5_H, title, items,
        C["dash_bg"], C["dash"], item_fs=6.1)

layer_label(ax, FW/2, L5_Y + L5_H + 0.18, "  ANALYTICS DASHBOARD (index.html)  ", C["dash"])
horiz_bar(ax, 0.45, 16.25, L5_Y + L5_H + 0.13, C["dash"], 1.4)

# ══════════════════════════════════════════════════════════════════════
# VERTICAL CONNECTOR LINE (main spine)
# ══════════════════════════════════════════════════════════════════════
ax.plot([FW/2, FW/2], [L5_Y+L5_H+0.13, L1_Y],
        color=C["conn"], lw=0.8, ls="--", zorder=0, alpha=0.45)

# ══════════════════════════════════════════════════════════════════════
# FOOTER
# ══════════════════════════════════════════════════════════════════════
legend = [
    (C["mt4"],  "MT4 Terminal (MQL4)"),
    (C["api"],  "FastAPI Backend"),
    (C["eng"],  "Business Engines"),
    (C["db"],   "Data Store"),
    (C["dash"], "Dashboard"),
]
for i,(color,label) in enumerate(legend):
    lx = 1.0 + i*3.1
    ax.add_patch(FancyBboxPatch((lx, 0.05), 0.22, 0.14,
        boxstyle="round,pad=0.01", facecolor=color,
        edgecolor="none", zorder=5))
    ax.text(lx+0.28, 0.12, label, fontsize=6.2, va="center", color=C["fg"])

ax.text(FW-0.30, 0.12, "V19 FX Prop Desk  |  2026",
        ha="right", va="center", fontsize=6.0, color=C["sub"])

# ══════════════════════════════════════════════════════════════════════
# SAVE
# ══════════════════════════════════════════════════════════════════════
out = r"D:\PJ\EA\V19_EA_Architecture.pdf"
plt.savefig(out, format="pdf", dpi=200, bbox_inches="tight",
            facecolor=fig.get_facecolor())
plt.close()
print(f"PDF saved → {out}")
