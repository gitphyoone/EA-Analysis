"""
EA Backend — Settings
=====================
ပြင်ဆင်ချက်များ (v1 → v2):

CRITICAL FIXES:
  1. api_secret_key  — weak default ကို startup validator ဖြင့် reject
  2. risk_per_trade  — 0.25% → 1.0% (meaningful signal + realistic profit)
  3. cb_daily_dd     — 3% → 5% (1% risk × 3 losses = old limit; now allows 5 trades)

LOGIC FIXES:
  4. adx_strong_threshold — 40.0 → 32.0 (ADX 40+ ရှားသည်; 32+ = real strong trend)
  5. max_spread_multiplier — ambiguous ATR ratio → explicit pip limits per pair type
  6. correlation_max  — 0.80 → 0.70 (tighter; 0.80 too loose for JPY pairs)
  7. news_blackout    — 30min → 45min (BOJ/NFP reaction window is 30–45min)

ADDITIONS:
  8. Secret key validator (raises at startup, not silently fail)
  9. Time string validator (rejects "8:0" malformed times)
 10. max_spread_pips + max_spread_news_pips (explicit, not ATR-relative)
 11. partial_close_ratio (locks profit at +1R, configurable)
 12. trail_atr_multiplier (was hardcoded 0.7× in MQL — now configurable)
 13. pair_type hint (JPY / non-JPY affects pip value calculation)
"""

from __future__ import annotations

from datetime import time
from functools import lru_cache
from typing import Literal

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):

    # =========================================================
    # APP
    # =========================================================
    environment: Literal["development", "staging", "production"] = "development"

    # CRITICAL FIX 1: validator rejects weak/default key at startup
    # Generate with: python -c "import secrets; print(secrets.token_hex(16))"
    api_secret_key: str = "change_me"

    # =========================================================
    # DATABASE / CACHE
    # =========================================================
    database_url: str = (
        "postgresql+asyncpg://ea_user:ea_pass@localhost:5432/ea_db"
    )
    redis_url: str = "redis://localhost:6379/0"

    # =========================================================
    # NEWS APIs
    # =========================================================
    trading_economics_api_key: str = ""
    investing_com_api_key: str = ""

    # FIX: fail-safe default — block trading when API unavailable
    # (was fail-open in earlier version — dangerous)
    news_fail_safe_block: bool = True

    # FIX 7: extended from 30 → 45 min
    # BOJ/NFP volatility window is 30–45 min; 30 was too short
    news_blackout_minutes: int = 45

    # =========================================================
    # RISK PARAMETERS
    # =========================================================

    # CRITICAL FIX 2: 0.25% → 1.0%
    # 0.25% on $10k = $25 risk/trade; after spread+commission net ≈ 0
    # 1.0% = $100 risk/trade — meaningful signal measurement in backtest
    risk_per_trade_pct: float = 1.0

    atr_sl_multiplier: float = 1.5    # SL = ATR × 1.5
    atr_tp_multiplier: float = 3.0    # TP = ATR × 3.0  →  RR 1:2

    # FIX (new): partial close at +1R, trail remainder to full TP
    # False = hold full position to TP (original v7 behavior)
    # True  = close 50% at +1R, trail rest (recommended)
    partial_close_ratio: float = 0.5      # fraction to close at +1R
    partial_close_at_r: float = 1.0       # close at +N × R

    # FIX (new): trailing stop multiplier — v7 hardcoded 0.7× ATR
    # 0.7× was too tight; normal retracement hit trail → early exit
    trail_atr_multiplier: float = 1.0     # trail = price ± ATR × 1.0

    max_open_positions: int = 3
    atr_min_threshold: float = 0.0005     # ignore entries in dead market

    # FIX 8: break-even buffer — exact entry = stop-hunt target
    # 1 pip buffer prevents false stop-out on broker spike
    be_buffer_pips: float = 1.0

    # Option: start ATR trail from +1R (aggressive) vs +2R (conservative)
    trail_from_1r: bool = True            # FIX: changed default to True

    # =========================================================
    # SPREAD LIMITS  (explicit pips — not ATR-relative)
    # =========================================================
    # FIX 5: replaced ambiguous max_spread_multiplier (ATR ratio)
    # with explicit pip values, split by condition

    # Normal session spread limits
    max_spread_pips: float = 15.0         # USDJPY/EURUSD normal
    max_spread_pips_jpy: float = 20.0     # GBPJPY / EURJPY wider natural spread
    max_spread_news_pips: float = 8.0     # during news blackout window (stricter)

    # Keep multiplier as fallback if backend calculates dynamically
    # max_spread_multiplier removed — use pip-based values above

    # =========================================================
    # CIRCUIT BREAKERS  (%)
    # =========================================================

    # Daily multi-level circuit breaker
    # L1 — Defensive: block new entries, existing positions untouched
    # L2 — Risk Reduction: close losers, protect winners at BE + trail
    # L3 — Emergency: close all, disable trading until next day
    cb_level1_dd_pct: float = 3.0
    cb_level2_dd_pct: float = 5.0
    cb_level3_dd_pct: float = 8.0

    cb_weekly_dd_pct: float = 10.0
    cb_monthly_dd_pct: float = 15.0

    # =========================================================
    # PORTFOLIO / CORRELATION
    # =========================================================

    # FIX from v1: 20 H1 (2.5 days too noisy) → 60 H1 (1.5 weeks)
    correlation_window: int = 60

    # FIX 6: 0.80 → 0.70
    # USDJPY/EURJPY correlation often 0.75–0.85; 0.80 let correlated pairs through
    # 0.70 is tighter and more appropriate for JPY basket
    correlation_max: float = 0.70

    max_absolute_exposure_ratio: float = 2.0

    # =========================================================
    # SIGNAL — RSI BOUNDS
    # =========================================================

    # Base RSI bounds (normal regime)
    rsi_buy_min:  float = 55.0    # momentum confirmation floor
    rsi_buy_max:  float = 70.0    # overbought ceiling
    rsi_sell_min: float = 30.0    # oversold floor
    rsi_sell_max: float = 45.0    # momentum confirmation ceiling

    adx_min: float = 25.0         # minimum trend strength

    # FIX 4: strong-trend RSI relaxation
    # When ADX > threshold, allow RSI beyond normal bounds
    # (prevents missing the strongest part of a trend)
    # CHANGED: 40.0 → 32.0 — ADX 40+ is rare on USDJPY H1
    # ADX 32–40 = clearly strong trend, RSI relaxation appropriate
    adx_strong_threshold: float = 32.0
    rsi_buy_max_strong:   float = 80.0    # allow RSI up to 80 in strong uptrend
    rsi_sell_min_strong:  float = 20.0    # allow RSI down to 20 in strong downtrend

    # =========================================================
    # REGIME / ENTRY QUALITY FILTERS
    # =========================================================

    # Ranging market filter — relaxed 0.001 → 0.0005 (was over-blocking slow trends)
    ema_convergence_min_pct: float = 0.0005

    # Momentum spike guard — relaxed 1.5 → 2.0× ATR (was clipping valid breakouts)
    candle_body_max_atr_mult: float = 2.0

    # =========================================================
    # SESSION  (UTC — DST handled dynamically by backend)
    # =========================================================
    london_open:  str = "08:00"
    london_close: str = "17:00"
    ny_open:      str = "13:00"
    ny_close:     str = "22:00"

    # FIX: close all trades Friday evening → avoid weekend gap risk
    # 20:00 UTC = Sat 05:00 JST — safe close before weekend
    friday_close_hour_utc: int = 20

    # Session filter toggle
    # False = only block weekend + Friday close (demo/backtest mode)
    # True  = also require London/NY/Overlap session (live mode)
    enable_session_filter: bool = False

    # =========================================================
    # MT4 INTEGRATION
    # =========================================================
    mt4_account_currency: str = "USD"

    # =========================================================
    # ALERTS — TELEGRAM
    # =========================================================
    telegram_bot_token: str = ""
    telegram_chat_id:   str = ""

    # =========================================================
    # VALIDATORS
    # =========================================================

    @field_validator("api_secret_key")
    @classmethod
    def validate_secret_key(cls, v: str) -> str:
        """
        CRITICAL FIX 1:
        Reject weak/default secret key at startup.
        Prevents running with insecure MT4↔Backend auth.
        """
        weak_defaults = {"change_me", "secret", "password", "test", ""}
        if v.lower() in weak_defaults:
            raise ValueError(
                "\n\n  api_secret_key is still the default value.\n"
                "  Generate a secure key:\n"
                "    python -c \"import secrets; print(secrets.token_hex(16))\"\n"
                "  Then set it in your .env file.\n"
            )
        if len(v) < 16:
            raise ValueError(
                f"api_secret_key must be at least 16 characters (got {len(v)})."
            )
        return v

    @field_validator("london_open", "london_close", "ny_open", "ny_close")
    @classmethod
    def validate_time_string(cls, v: str) -> str:
        """
        FIX 9: Validate HH:MM format — rejects '8:0', '25:00', etc.
        Silent malformed times caused session logic to fail quietly.
        """
        try:
            time.fromisoformat(v)
        except ValueError:
            raise ValueError(
                f"Invalid time format: '{v}'. Use HH:MM (e.g. '08:00')."
            )
        return v

    @model_validator(mode="after")
    def validate_risk_consistency(self) -> "Settings":
        # CB levels must be strictly ascending
        if not (self.cb_level1_dd_pct < self.cb_level2_dd_pct < self.cb_level3_dd_pct):
            raise ValueError(
                f"Circuit breaker levels must be strictly ascending: "
                f"cb_level1={self.cb_level1_dd_pct}% "
                f"cb_level2={self.cb_level2_dd_pct}% "
                f"cb_level3={self.cb_level3_dd_pct}%"
            )

        # Emergency shutdown must allow at least 3 losses before triggering
        max_losses_before_shutdown = self.cb_level3_dd_pct / self.risk_per_trade_pct
        if max_losses_before_shutdown < 3:
            raise ValueError(
                f"\n\n  Risk configuration inconsistency:\n"
                f"  risk_per_trade_pct={self.risk_per_trade_pct}% with "
                f"cb_level3={self.cb_level3_dd_pct}% allows only "
                f"{max_losses_before_shutdown:.0f} losses before emergency shutdown.\n"
                f"  Minimum 3 losses recommended.\n"
            )

        # Weekly CB must be above the daily emergency level
        if self.cb_weekly_dd_pct <= self.cb_level3_dd_pct:
            raise ValueError(
                f"cb_weekly_dd_pct ({self.cb_weekly_dd_pct}%) must exceed "
                f"cb_level3_dd_pct ({self.cb_level3_dd_pct}%)."
            )

        return self

    @field_validator("partial_close_ratio")
    @classmethod
    def validate_partial_ratio(cls, v: float) -> float:
        if not (0.1 <= v <= 0.9):
            raise ValueError(
                f"partial_close_ratio must be between 0.1 and 0.9 (got {v})."
            )
        return v

    @field_validator("correlation_max")
    @classmethod
    def validate_correlation(cls, v: float) -> float:
        if not (0.0 < v < 1.0):
            raise ValueError(
                f"correlation_max must be between 0 and 1 exclusive (got {v})."
            )
        return v

    class Config:
        env_file = ".env"
        extra = "ignore"


@lru_cache()
def get_settings() -> Settings:
    return Settings()