"""
Pre-trade Engine — V19.1
========================
Re-entry and daily-loss guards from the V19.1 Exit Improvement Memo (RED list).
These run AFTER the signal engine has produced a BUY/SELL — they only ever
downgrade a live signal to NO_TRADE, never create one.

  memo §9  — 30-minute same-symbol cooldown after an SL
  memo §11 — same-symbol + same-direction re-entry waits for a fresh H1 candle
  memo §16 — daily realised-loss soft stop (no new entries for the rest of the day)

Kept pure (no DB / no I/O) so it unit-tests like SignalEngine / RiskEngine —
the caller (routers/signals.py) does the DB queries and passes plain data in.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
from typing import Optional

from ..config import Settings


@dataclass
class PretradeDecision:
    allowed: bool
    reason: Optional[str] = None            # one of the RejectReason literals when blocked
    detail: Optional[str] = None            # human-readable context for logs


class PretradeEngine:
    def __init__(self, settings: Settings):
        self.settings = settings

    def check(
        self,
        *,
        symbol: str,
        direction: str,                     # "BUY" | "SELL"
        last_trades: list[dict],            # recent trade_history rows, NEWEST FIRST
                                            #   keys: exit_reason, direction, closed_at
        latest_h1_candle_ts: Optional[datetime],
        now: datetime,
        daily_realized_loss: Decimal,       # signed or unsigned — abs() is taken
        equity: Optional[Decimal],
    ) -> PretradeDecision:
        cfg = self.settings

        last = last_trades[0] if last_trades else None
        last_was_sl = bool(last) and (last.get("exit_reason") == "SL")
        last_closed_at = last.get("closed_at") if last else None
        if last_closed_at is not None and last_closed_at.tzinfo is None and now.tzinfo is not None:
            last_closed_at = last_closed_at.replace(tzinfo=now.tzinfo)

        # ── memo §9 — SL cooldown (any direction) ─────────────────────
        if last_was_sl and last_closed_at is not None and cfg.sl_cooldown_minutes > 0:
            elapsed = now - last_closed_at
            if elapsed < timedelta(minutes=cfg.sl_cooldown_minutes):
                mins_left = cfg.sl_cooldown_minutes - int(elapsed.total_seconds() // 60)
                return PretradeDecision(
                    False, "SL_COOLDOWN",
                    f"{symbol} SL {int(elapsed.total_seconds() // 60)}min ago; "
                    f"{mins_left}min cooldown remaining",
                )

        # ── memo §11 — same-direction re-entry waits for a new H1 candle ──
        if (
            cfg.reentry_wait_new_candle
            and last_was_sl
            and last_closed_at is not None
            and last.get("direction") == direction
        ):
            if latest_h1_candle_ts is not None:
                cand_ts = latest_h1_candle_ts
                if cand_ts.tzinfo is None and last_closed_at.tzinfo is not None:
                    cand_ts = cand_ts.replace(tzinfo=last_closed_at.tzinfo)
                if cand_ts <= last_closed_at:
                    return PretradeDecision(
                        False, "REENTRY_WAIT_CANDLE",
                        f"{symbol} {direction} stopped out; waiting for the next H1 close "
                        f"(last candle {cand_ts:%Y-%m-%d %H:%M} <= SL {last_closed_at:%H:%M})",
                    )

        # ── memo §16 — daily realised-loss soft stop ─────────────────
        if equity is not None and equity > 0 and cfg.daily_loss_limit_pct < 100:
            loss_pct = abs(float(daily_realized_loss)) / float(equity) * 100.0
            if loss_pct >= cfg.daily_loss_limit_pct:
                return PretradeDecision(
                    False, "DAILY_LOSS_LIMIT",
                    f"daily realised loss {loss_pct:.2f}% >= "
                    f"{cfg.daily_loss_limit_pct:.2f}% — no new entries today",
                )

        return PretradeDecision(True)
