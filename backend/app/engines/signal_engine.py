"""
Signal Engine — Phase 1
Fixes applied:
  - FIX: EMA convergence (regime) check — flat/ranging EMAs reject entry
  - FIX: Candle body size guard — reject entry after momentum spike (body > 1.5×ATR)
  - FIX: Strong-ADX RSI relaxation — when ADX > 40, RSI cap is widened to 80/20
         (original cap of 70/30 blocked the strongest trend entries)
  - FIX: Optional multi-timeframe bias — pass H4/D1 trend direction to filter counter-trend entries
  - FIX: EMA10/20 short-term alignment (Option B score-based) — misalignment costs 1 point
         but does NOT hard-reject; strong setups (7/8) still trade through it
  - FIX: EMA50/200 slope filter — EMAs must be rising (BUY) or falling (SELL)
         prevents entries when trend is flattening or reversing at peak/trough
  - FIX: Dynamic score threshold — strong ADX (> adx_strong_threshold) lowers
         required score from 7 to 6, allowing high-conviction entries through
         even when one minor condition (e.g. EMA slope lag) is borderline
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
        ema10: Optional[Decimal] = None,          # FIX: EMA10 for short-term alignment score
        ema20: Optional[Decimal] = None,          # FIX: EMA20 for short-term alignment score
        ema50_prev: Optional[Decimal] = None,     # FIX: EMA50 bar[2] for slope detection
        ema200_prev: Optional[Decimal] = None,    # FIX: EMA200 bar[2] for slope detection
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

        # ── EMA short-term alignment (score-based, not hard reject) ──
        # EMA10 > EMA20 in uptrend → short-term bullish momentum confirmed
        # EMA10 < EMA20 in downtrend → short-term bearish momentum confirmed
        # None if ema10/ema20 not provided → no penalty (backward compat)
        if ema10 is not None and ema20 is not None:
            ema_short_ok: Optional[bool] = (
                (trend_up   and float(ema10) > float(ema20)) or
                (trend_down and float(ema10) < float(ema20))
            )
            ema_short_score = int(ema_short_ok)
        else:
            ema_short_ok = None
            ema_short_score = 1   # no data — no penalty

        # ── EMA Slope filter (score-based) ───────────────────────────
        # EMA50/200 must be rising for BUY, falling for SELL.
        # Prevents entries when trend is flattening at peak/trough.
        # Uses bar[2] (prev) vs bar[1] (current) slope.
        # None if prev values not provided → no penalty (backward compat)
        if ema50_prev is not None and ema200_prev is not None:
            ema50_rising  = float(ema50)  > float(ema50_prev)
            ema200_rising = float(ema200) > float(ema200_prev)
            if trend_up:
                # BUY: both EMAs should be rising
                ema_slope_ok: Optional[bool] = ema50_rising and ema200_rising
            elif trend_down:
                # SELL: both EMAs should be falling
                ema_slope_ok = (not ema50_rising) and (not ema200_rising)
            else:
                ema_slope_ok = False
            ema_slope_score = int(ema_slope_ok)
        else:
            ema_slope_ok = None
            ema_slope_score = 1   # no data — no penalty

        # ── Score system ──────────────────────────────────────────────
        # 9 components (DI excluded); base required = 7/9
        # Dynamic threshold: strong ADX lowers required to 6/9
        #   → high-conviction momentum entries still trade through
        #     even when one minor condition (e.g. slope lag) is borderline
        score = sum([int(ema_trend), int(regime_ok), int(body_ok), htf_score,
                     int(rsi_ok), int(adx_ok), int(atr_ok),
                     ema_short_score, ema_slope_score])

        # Dynamic threshold: relax by 1 when ADX confirms strong trend
        _required = 6 if adx_val > cfg.adx_strong_threshold else 7

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
                rsi_ok, adx_ok, atr_ok, ema_short_ok, ema_slope_ok
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
            ema_short_ok=ema_short_ok,
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
        ema_short_ok: Optional[bool],
        ema_slope_ok: Optional[bool],
    ) -> RejectReason:
        # Score < required means 2+ conditions failed. Report highest-priority failure.
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
        if ema_slope_ok is False:
            return "EMA_SLOPE_FLAT"
        if ema_short_ok is False:
            return "EMA_SHORT_COUNTER"
        if htf_score == 0:
            return "HTF_COUNTER_TREND"
        return "MULTI_CONDITION_FAIL"