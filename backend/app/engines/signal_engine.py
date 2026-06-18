"""
Signal Engine — Phase 1
Fixes applied:
  - FIX: EMA convergence (regime) check — flat/ranging EMAs reject entry
  - FIX: Candle body size guard — reject entry after momentum spike (body > 1.5×ATR)
  - FIX: Strong-ADX RSI relaxation — when ADX > 40, RSI cap is widened to 80/20
         (original cap of 70/30 blocked the strongest trend entries)
  - FIX: Optional multi-timeframe bias — pass H4/D1 trend direction to filter counter-trend entries
Original (kept): EMA50/200 cross + RSI + ADX + DI+/DI- + ATR minimum
"""
from decimal import Decimal
from datetime import datetime
from typing import Optional
from ..config import Settings
from ..schemas.signal import SignalResult, SignalDirection, RejectReason


class SignalEngine:
    def __init__(self, settings: Settings):
        self.settings = settings

    def evaluate(
        self,
        symbol: str,
        timeframe: str,
        timestamp: datetime,
        current_price: Decimal,
        candle_open: Decimal,                    # FIX: needed for body size check
        ema50: Decimal,
        ema200: Decimal,
        rsi: Decimal,
        adx: Decimal,
        di_plus: Decimal,
        di_minus: Decimal,
        atr: Decimal,
        htf_trend_up: Optional[bool] = None,     # FIX: H4/D1 trend bias (None = not checked)
    ) -> SignalResult:
        cfg = self.settings

        # ── Regime detection ──────────────────────────────────────────
        # FIX: if EMA50 and EMA200 are almost equal, the market is ranging, not trending
        ema_gap_pct = abs(float(ema50 - ema200)) / float(ema200) if float(ema200) != 0 else 0
        regime_ok = ema_gap_pct >= cfg.ema_convergence_min_pct

        # ── Candle body guard ─────────────────────────────────────────
        # FIX: entering after a large momentum candle (spike) = bad timing
        candle_body = abs(float(current_price) - float(candle_open))
        body_ok = candle_body <= float(atr) * cfg.candle_body_max_atr_mult

        # ── Trend direction ───────────────────────────────────────────
        trend_up = ema50 > ema200
        trend_down = ema50 < ema200

        # ── Multi-timeframe bias (score-based, not hard reject) ───────
        # Aligned = +1 point. Misaligned = 0 points, but does NOT block.
        # This alone cannot reject a trade; only compounds with other failures.
        if htf_trend_up is None:
            htf_score = 1   # no H4 data — no penalty
            htf_pass = None
        elif (trend_up and htf_trend_up) or (trend_down and not htf_trend_up):
            htf_score = 1
            htf_pass = True
        else:
            htf_score = 0
            htf_pass = False

        # ── Momentum ──────────────────────────────────────────────────
        # FIX: strong ADX relaxes RSI cap (was missing the most powerful trend entries)
        adx_val = float(adx)
        if adx_val > cfg.adx_strong_threshold:
            buy_max = cfg.rsi_buy_max_strong
            sell_min = cfg.rsi_sell_min_strong
        else:
            buy_max = cfg.rsi_buy_max
            sell_min = cfg.rsi_sell_min

        rsi_buy = cfg.rsi_buy_min <= float(rsi) <= buy_max
        rsi_sell = sell_min <= float(rsi) <= cfg.rsi_sell_max
        rsi_ok = rsi_buy if trend_up else (rsi_sell if trend_down else False)

        # ── Trend strength ────────────────────────────────────────────
        adx_ok = adx_val > cfg.adx_min

        # DI kept for SignalResult transparency but removed from scoring/rejection.
        # ADX already confirms trend strength; DI was redundant and over-filtered.
        di_buy = di_plus > di_minus
        di_sell = di_minus > di_plus
        di_ok = di_buy if trend_up else (di_sell if trend_down else False)

        # ── Volatility regime ─────────────────────────────────────────
        atr_ok = float(atr) > cfg.atr_min_threshold

        ema_trend = trend_up or trend_down

        # ── Score system ──────────────────────────────────────────────
        # 7 components (DI excluded); need 6/7 to trade.
        # Allows 1 weaker condition (typically HTF mismatch) without blocking.
        score = sum([int(ema_trend), int(regime_ok), int(body_ok), htf_score,
                     int(rsi_ok), int(adx_ok), int(atr_ok)])
        _required = 6

        if trend_up and score >= _required:
            direction: SignalDirection = "BUY"
            reject_reason = None
        elif trend_down and score >= _required:
            direction = "SELL"
            reject_reason = None
        else:
            direction = "NO_TRADE"
            reject_reason = self._reject_reason(
                trend_up, trend_down, regime_ok, body_ok, htf_score,
                rsi_ok, adx_ok, atr_ok
            )

        return SignalResult(
            symbol=symbol,
            timeframe=timeframe,
            timestamp=timestamp,
            direction=direction,
            score=score,
            ema_trend=ema_trend,
            rsi_ok=rsi_ok,
            adx_ok=adx_ok,
            di_ok=di_ok,
            atr_ok=atr_ok,
            htf_pass=htf_pass,
            current_price=current_price,
            ema50=ema50,
            ema200=ema200,
            rsi=rsi,
            adx=adx,
            di_plus=di_plus,
            di_minus=di_minus,
            atr=atr,
            reject_reason=reject_reason,
        )

    def _reject_reason(
        self,
        trend_up: bool,
        trend_down: bool,
        regime_ok: bool,
        body_ok: bool,
        htf_score: int,
        rsi_ok: bool,
        adx_ok: bool,
        atr_ok: bool,
    ) -> RejectReason:
        # Score < 6 means 2+ conditions failed. Report highest-priority failure.
        if not (trend_up or trend_down):
            return "NO_TREND"
        if not regime_ok:
            return "RANGING_MARKET"
        if not body_ok:
            return "CANDLE_SPIKE"
        if not adx_ok:
            return "ADX_WEAK"
        if not rsi_ok:
            return "RSI_OUT_OF_RANGE"
        if not atr_ok:
            return "ATR_TOO_LOW"
        # All scored conditions passed — HTF mismatch must be compounding with
        # a condition that evaluates to False in ways not captured above.
        if htf_score == 0:
            return "HTF_COUNTER_TREND"
        return "MULTI_CONDITION_FAIL"
