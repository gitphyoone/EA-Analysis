from pydantic import BaseModel
from typing import Literal, Optional
from decimal import Decimal
from datetime import datetime


SignalDirection = Literal["BUY", "SELL", "NO_TRADE"]

RejectReason = Literal[
    "NO_TREND",             # EMA50/200 not crossed — no directional bias
    "RANGING_MARKET",       # EMA gap too small — EMAs converged / flat
    "CANDLE_SPIKE",         # Candle body > max_atr_mult × ATR — momentum spike
    "ADX_WEAK",             # ADX below minimum — trend not strong enough
    "RSI_OUT_OF_RANGE",     # RSI outside buy/sell window for this direction
    "ATR_TOO_LOW",          # ATR below minimum — insufficient volatility
    "EMA_SLOPE_FLAT",       # EMA50/200 slope disagreement — trend losing momentum
    "EMA_SHORT_COUNTER",    # EMA10/20 counter to H1 trend — bounce entry risk
    "HTF_COUNTER_TREND",    # H4/D1 trend opposes entry direction
    "MULTI_CONDITION_FAIL", # 2+ conditions failed — no single dominant reason
    "OFF_SESSION",          # Outside allowed trading session window
    "FRIDAY_CLOSE",         # Friday close — new entries blocked before weekend
]


class SignalResult(BaseModel):
    symbol: str
    timeframe: str
    timestamp: datetime
    direction: SignalDirection
    score: int                              # number of conditions met (max 8)
    ema_trend: bool
    rsi_ok: bool
    adx_ok: bool
    di_ok: bool
    atr_ok: bool
    htf_pass: Optional[bool] = None        # None = no H4 data; True/False = aligned/counter
    ema_short_ok: Optional[bool] = None    # None = no EMA10/20 data; True/False = aligned/counter
    current_price: Decimal
    ema50: Decimal
    ema200: Decimal
    rsi: Decimal
    adx: Decimal
    di_plus: Decimal
    di_minus: Decimal
    atr: Decimal
    reject_reason: Optional[RejectReason] = None


class CircuitBreakerState(BaseModel):
    triggered: bool
    level: Optional[Literal["LEVEL_1", "LEVEL_2", "LEVEL_3", "WEEKLY", "MONTHLY"]] = None
    reason: Optional[str] = None
    daily_dd_pct: float = 0.0
    weekly_dd_pct: float = 0.0
    monthly_dd_pct: float = 0.0
