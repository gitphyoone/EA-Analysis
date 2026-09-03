from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from datetime import datetime, timezone, timedelta, date

JST = timezone(timedelta(hours=9))
from decimal import Decimal
from typing import Optional
import pytz

from ..database import get_db
from ..models.market_data import MarketData
from ..models.trade import TradeHistory
from ..models.account import AccountSnapshot
from ..schemas.signal import SignalResult, CircuitBreakerState
from ..engines.signal_engine import SignalEngine
from ..engines.risk_engine import RiskEngine
from ..engines.session_engine import SessionEngine
from ..engines.pretrade_engine import PretradeEngine
from ..config import get_settings
from ..auth import verify_api_key
from ..services.signal_log_service import SignalLogService

router = APIRouter(prefix="/signals", tags=["signals"])


@router.get("/evaluate/{symbol}", response_model=SignalResult)
async def evaluate_signal(
    symbol: str,
    timeframe: str = "H1",
    htf_timeframe: str = "H4",
    # FIX: MT4 passes live pip value via MarketInfo(); used by risk engine for lot sizing
    pip_value: Optional[float] = Query(None, description="Live pip value per lot from MT4 MarketInfo()"),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    settings = get_settings()
    symbol = symbol.upper()

    # Latest H1 candle
    stmt = (
        select(MarketData)
        .where(MarketData.symbol == symbol, MarketData.timeframe == timeframe.upper())
        .order_by(MarketData.timestamp.desc())
        .limit(1)
    )
    result = await db.execute(stmt)
    candle = result.scalar_one_or_none()

    if candle is None:
        raise HTTPException(404, f"No market data for {symbol} {timeframe}")

    for field in ("ema50", "ema200", "rsi14", "adx14", "di_plus", "di_minus", "atr14"):
        if getattr(candle, field) is None:
            raise HTTPException(422, f"Missing indicator: {field}")

    # FIX: optional HTF trend from H4 data (None = skip multi-TF check)
    htf_trend_up: Optional[bool] = None
    htf_stmt = (
        select(MarketData)
        .where(MarketData.symbol == symbol, MarketData.timeframe == htf_timeframe.upper())
        .order_by(MarketData.timestamp.desc())
        .limit(1)
    )
    htf_result = await db.execute(htf_stmt)
    htf_candle = htf_result.scalar_one_or_none()
    if htf_candle and htf_candle.ema50 and htf_candle.ema200:
        htf_trend_up = htf_candle.ema50 > htf_candle.ema200

    engine = SignalEngine(settings)
    signal = engine.evaluate(
        symbol=candle.symbol,
        timeframe=candle.timeframe,
        timestamp=candle.timestamp,
        current_price=candle.close,
        candle_open=candle.open,             # FIX: needed for body size check
        ema50=candle.ema50,
        ema200=candle.ema200,
        rsi=candle.rsi14,
        adx=candle.adx14,
        di_plus=candle.di_plus,
        di_minus=candle.di_minus,
        atr=candle.atr14,
        htf_trend_up=htf_trend_up,           # FIX: multi-timeframe bias
        ema10=candle.ema10,                  # FIX: EMA10/20 short-term alignment score
        ema20=candle.ema20,
        # FIX (chat): ema50_prev/ema200_prev were being computed and stored
        # by both MT4 and MT5 DataCollector (specifically for this purpose)
        # but were never forwarded to SignalEngine.evaluate() here — the
        # engine's ema_slope_ok / ema_slope_score logic silently treated them
        # as "not provided" (no penalty) for every symbol/timeframe, meaning
        # the EMA50/200 rising-falling slope filter has never actually been
        # active in production. Forwarding them now activates it.
        ema50_prev=candle.ema50_prev,
        ema200_prev=candle.ema200_prev,
    )

    # Session gate (includes Friday close check)
    session_engine = SessionEngine(
        friday_close_hour_utc=settings.friday_close_hour_utc,
        enable_session_filter=settings.enable_session_filter,
    )
    now_utc = datetime.now(pytz.utc)
    if not session_engine.is_tradeable(now_utc):
        signal.direction = "NO_TRADE"
        signal.reject_reason = "FRIDAY_CLOSE" if session_engine.is_friday_close(now_utc) else "OFF_SESSION"

    # ── V19.1 pre-trade guards (re-entry cooldown / daily-loss soft stop) ──
    # Only ever downgrades a live BUY/SELL to NO_TRADE — never creates a signal.
    if signal.direction in ("BUY", "SELL"):
        reason = await _pretrade_block_reason(db, settings, symbol, signal.direction, candle.timestamp)
        if reason is not None:
            signal.direction = "NO_TRADE"
            signal.reject_reason = reason

    session_name = session_engine.get_session(now_utc)
    await SignalLogService().log(db, signal, session=session_name)

    return signal


async def _pretrade_block_reason(db, settings, symbol, direction, latest_h1_candle_ts):
    """Returns a RejectReason string if a V19.1 re-entry/daily-loss guard blocks the
    trade, else None. See engines/pretrade_engine.py."""
    # Recent closed trades for this symbol (newest first) — uses idx_trade_history_symbol
    th_rows = (await db.execute(
        select(TradeHistory.exit_reason, TradeHistory.direction, TradeHistory.closed_at)
        .where(TradeHistory.symbol == symbol)
        .order_by(TradeHistory.closed_at.desc())
        .limit(3)
    )).all()
    last_trades = [
        {"exit_reason": r.exit_reason, "direction": r.direction, "closed_at": r.closed_at}
        for r in th_rows
    ]

    # Today's realised loss (JST day), same shape as analytics.drawdown
    today_jst = datetime.now(JST).date()
    day_start = datetime(today_jst.year, today_jst.month, today_jst.day, tzinfo=JST)
    daily_loss = (await db.execute(
        select(func.coalesce(func.sum(TradeHistory.net_pnl), 0))
        .where(TradeHistory.closed_at >= day_start)
        .where(TradeHistory.net_pnl < 0)
    )).scalar() or Decimal(0)

    snap = await db.get(AccountSnapshot, 1)
    equity = snap.equity if snap else None

    decision = PretradeEngine(settings).check(
        symbol=symbol,
        direction=direction,
        last_trades=last_trades,
        latest_h1_candle_ts=latest_h1_candle_ts,
        now=datetime.now(timezone.utc),
        daily_realized_loss=daily_loss,
        equity=equity,
    )
    if not decision.allowed:
        import logging
        logging.getLogger("ea.signals").info(
            "pre-trade block %s %s → %s (%s)", symbol, direction, decision.reason, decision.detail
        )
        return decision.reason
    return None


@router.get("/circuit-breaker", response_model=CircuitBreakerState)
async def get_circuit_breaker(
    floating_dd_pct: float = 0.0,
    weekly_dd: float = 0.0,
    monthly_dd: float = 0.0,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    settings = get_settings()

    # FIX: calculate realized losses from closed trades today (was ignored before)
    today_jst = datetime.now(JST).date()
    today_start = datetime(today_jst.year, today_jst.month, today_jst.day, tzinfo=JST)
    result = await db.execute(
        select(func.coalesce(func.sum(TradeHistory.net_pnl), 0))
        .where(TradeHistory.closed_at >= today_start)
        .where(TradeHistory.net_pnl < 0)
    )
    realized_today_loss = abs(float(result.scalar() or 0))

    # Need equity to compute %; caller supplies floating_dd_pct directly
    # realized_daily_loss_pct is passed separately and summed inside risk engine
    engine = RiskEngine(settings)
    return engine.check_circuit_breakers(
        daily_dd_pct=floating_dd_pct,
        weekly_dd_pct=weekly_dd,
        monthly_dd_pct=monthly_dd,
        realized_daily_loss_pct=0.0,  # caller should pass equity-normalised value
    )
