from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from datetime import date, datetime, timezone, timedelta
from decimal import Decimal

JST = timezone(timedelta(hours=9))  # Japan Standard Time

from ..database import get_db
from ..models.trade import Trade, TradeHistory
from ..models.journal import QuantJournal
from ..models.account import AccountSnapshot
from ..models.signal_log import SignalLog
from ..auth import verify_api_key

router = APIRouter(prefix="/analytics", tags=["analytics"])


@router.get("/account")
async def account_summary(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    # Primary: live snapshot POSTed by DataCollector every minute
    snap = await db.get(AccountSnapshot, 1)
    if snap:
        return {"equity": float(snap.equity), "balance": float(snap.balance) if snap.balance else None,
                "source": "snapshot", "date": snap.updated_at.strftime("%Y-%m-%dT%H:%M:%SZ")}

    # Secondary: latest quant_journal entry (written on trade close)
    j = await db.execute(select(QuantJournal).order_by(QuantJournal.date.desc()).limit(1))
    last_journal = j.scalar_one_or_none()
    if last_journal and last_journal.equity_close:
        return {"equity": float(last_journal.equity_close), "balance": None,
                "source": "journal", "date": str(last_journal.date)}

    # Fallback: account_equity from the most recent open trade
    t = await db.execute(
        select(Trade.account_equity, Trade.opened_at)
        .order_by(Trade.opened_at.desc())
        .limit(1)
    )
    last_trade = t.first()
    if last_trade and last_trade.account_equity:
        return {"equity": float(last_trade.account_equity), "balance": None,
                "source": "trade", "date": str(last_trade.opened_at)[:10]}

    return {"equity": None, "balance": None, "source": None, "date": None}


@router.get("/performance")
async def performance_summary(
    from_date: date = Query(default=None),
    to_date: date = Query(default=None),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    stmt = select(TradeHistory)
    if from_date:
        stmt = stmt.where(TradeHistory.closed_at >= datetime(from_date.year, from_date.month, from_date.day, tzinfo=JST))
    if to_date:
        stmt = stmt.where(TradeHistory.closed_at <= datetime(to_date.year, to_date.month, to_date.day, 23, 59, 59, tzinfo=JST))
    stmt = stmt.order_by(TradeHistory.closed_at)

    result = await db.execute(stmt)
    trades = result.scalars().all()

    if not trades:
        return {"trades": 0}

    net_pnls = [float(t.net_pnl or 0) for t in trades]
    wins = [p for p in net_pnls if p > 0]
    losses = [p for p in net_pnls if p < 0]
    r_multiples = [float(t.r_multiple or 0) for t in trades]

    gross_profit = sum(wins)
    gross_loss = abs(sum(losses))
    profit_factor = round(gross_profit / gross_loss, 4) if gross_loss > 0 else None
    win_rate = round(len(wins) / len(trades) * 100, 2)
    expectancy = round(sum(r_multiples) / len(r_multiples), 4) if r_multiples else 0

    # Sharpe (simplified, using R-multiples)
    import numpy as np
    if len(r_multiples) > 1:
        sharpe = round(float(np.mean(r_multiples) / np.std(r_multiples)) if np.std(r_multiples) > 0 else 0, 4)
    else:
        sharpe = 0

    return {
        "total_trades": len(trades),
        "winning_trades": len(wins),
        "losing_trades": len(losses),
        "win_rate_pct": win_rate,
        "gross_profit": round(gross_profit, 2),
        "gross_loss": round(gross_loss, 2),
        "net_pnl": round(sum(net_pnls), 2),
        "profit_factor": profit_factor,
        "expectancy_r": expectancy,
        "sharpe_ratio": sharpe,
        "avg_win": round(sum(wins) / len(wins), 2) if wins else 0,
        "avg_loss": round(sum(losses) / len(losses), 2) if losses else 0,
    }


@router.get("/drawdown")
async def drawdown_summary(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    UTC = timezone.utc
    today = datetime.now(UTC).date()
    week_start = today - timedelta(days=today.weekday())
    month_start = today.replace(day=1)

    def utc_day_start(d: date) -> datetime:
        return datetime(d.year, d.month, d.day, tzinfo=UTC)

    def utc_day_end(d: date) -> datetime:
        return datetime(d.year, d.month, d.day, 23, 59, 59, tzinfo=UTC)

    async def dd_for_period(start: date, end: date = None) -> float:
        # FIX: daily_loss was returning 0 because no end-date bound was set.
        # Without end=today, the query spans from 'start' to now (all-time for daily).
        # Pass end=today to correctly bound today-only losses.
        stmt = (
            select(func.sum(TradeHistory.net_pnl))
            .where(TradeHistory.closed_at >= utc_day_start(start))
            .where(TradeHistory.net_pnl < 0)
        )
        if end is not None:
            stmt = stmt.where(TradeHistory.closed_at <= utc_day_end(end))
        result = await db.execute(stmt)
        val = result.scalar()
        return float(val or 0)

    async def pnl_for_day(start: date) -> float:
        stmt = (
            select(func.sum(TradeHistory.net_pnl))
            .where(TradeHistory.closed_at >= utc_day_start(start))
            .where(TradeHistory.closed_at <= utc_day_end(start))
        )
        result = await db.execute(stmt)
        val = result.scalar()
        return float(val or 0)

    async def total_pnl_for_period(start: date) -> float:
        stmt = (
            select(func.sum(TradeHistory.net_pnl))
            .where(TradeHistory.closed_at >= utc_day_start(start))
        )
        result = await db.execute(stmt)
        val = result.scalar()
        return float(val or 0)

    daily_loss = await dd_for_period(today, today)   # FIX: bound to today only
    weekly_loss = await dd_for_period(week_start)
    monthly_loss = await dd_for_period(month_start)
    daily_pnl = await pnl_for_day(today)
    weekly_pnl = await total_pnl_for_period(week_start)
    monthly_pnl = await total_pnl_for_period(month_start)

    return {
        "daily_pnl": round(daily_pnl, 2),
        "daily_loss": round(daily_loss, 2),
        "weekly_loss": round(weekly_loss, 2),
        "monthly_loss": round(monthly_loss, 2),
        "weekly_pnl": round(weekly_pnl, 2),
        "monthly_pnl": round(monthly_pnl, 2),
    }


@router.get("/equity-curve")
async def equity_curve(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    result = await db.execute(
        select(QuantJournal).order_by(QuantJournal.date)
    )
    rows = result.scalars().all()
    return [
        {
            "date": str(r.date),
            "equity": float(r.equity_close or 0),
            "daily_pnl": float(r.daily_pnl or 0),
            "win_rate": float(r.win_rate or 0),
            "profit_factor": float(r.profit_factor or 0),
        }
        for r in rows
    ]


@router.get("/signal-rejects")
async def signal_rejects(
    days: int = Query(default=30, description="Look-back window in days"),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    since = datetime.now(JST) - timedelta(days=days)

    # Top reject reasons
    reason_rows = await db.execute(
        select(SignalLog.reject_reason, func.count().label("cnt"))
        .where(SignalLog.direction == "NO_TRADE", SignalLog.created_at >= since)
        .group_by(SignalLog.reject_reason)
        .order_by(func.count().desc())
    )
    by_reason = [{"reject_reason": r, "count": c} for r, c in reason_rows]

    # Daily breakdown
    daily_rows = await db.execute(
        select(
            func.date_trunc("day", SignalLog.created_at).label("day"),
            SignalLog.reject_reason,
            func.count().label("cnt"),
        )
        .where(SignalLog.direction == "NO_TRADE", SignalLog.created_at >= since)
        .group_by("day", SignalLog.reject_reason)
        .order_by("day")
    )
    by_day = [{"date": str(d.date()), "reject_reason": r, "count": c} for d, r, c in daily_rows]

    # Trade conversion rate
    total_row = await db.execute(
        select(func.count()).where(SignalLog.created_at >= since)
    )
    total = total_row.scalar() or 0

    traded_row = await db.execute(
        select(func.count()).where(
            SignalLog.direction != "NO_TRADE",
            SignalLog.created_at >= since,
        )
    )
    traded = traded_row.scalar() or 0

    conversion_pct = round(traded * 100.0 / total, 2) if total > 0 else 0.0

    return {
        "period_days": days,
        "total_evaluations": total,
        "traded": traded,
        "conversion_pct": conversion_pct,
        "by_reason": by_reason,
        "by_day": by_day,
    }


@router.get("/trade-history")
async def trade_history(
    limit: int = Query(default=20, ge=1, le=300),
    offset: int = Query(default=0, ge=0),
    symbol: str = Query(default=""),
    direction: str = Query(default=""),
    period: str = Query(default=""),   # today | week | month | "" (all)
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    stmt = select(TradeHistory)

    if symbol:
        stmt = stmt.where(TradeHistory.symbol.ilike(f"%{symbol}%"))
    if direction in ("BUY", "SELL"):
        stmt = stmt.where(TradeHistory.direction == direction)
    if period:
        now_jst = datetime.now(JST)
        today_j = now_jst.date()
        if period == "today":
            start = datetime(today_j.year, today_j.month, today_j.day, tzinfo=JST)
            stmt = stmt.where(TradeHistory.closed_at >= start)
        elif period == "week":
            ws = today_j - timedelta(days=today_j.weekday())
            stmt = stmt.where(TradeHistory.closed_at >= datetime(ws.year, ws.month, ws.day, tzinfo=JST))
        elif period == "month":
            ms = today_j.replace(day=1)
            stmt = stmt.where(TradeHistory.closed_at >= datetime(ms.year, ms.month, ms.day, tzinfo=JST))

    total_res = await db.execute(select(func.count()).select_from(stmt.subquery()))
    total = total_res.scalar() or 0

    stmt = stmt.order_by(TradeHistory.closed_at.desc()).offset(offset).limit(limit)
    rows = (await db.execute(stmt)).scalars().all()

    trades = [
        {
            "ticket": r.ticket,
            "symbol": r.symbol,
            "direction": r.direction,
            "entry": float(r.entry_price),
            "exit": float(r.exit_price),
            "sl": float(r.stop_loss or 0),
            "tp": float(r.take_profit or 0),
            "lots": float(r.lot_size),
            "spread": float(r.spread or 0),
            "commission": float(r.commission or 0),
            "swap": float(r.swap or 0),
            "gross_pnl": float(r.gross_pnl or 0),
            "net_pnl": float(r.net_pnl or 0),
            "r_multiple": float(r.r_multiple or 0),
            "exit_reason": r.exit_reason,
            "session": r.session,
            "opened_at": str(r.opened_at),
            "closed_at": str(r.closed_at),
            "signal_score": float(r.signal_score) if r.signal_score is not None else None,
            "signal_rsi":   float(r.signal_rsi)   if r.signal_rsi   is not None else None,
            "signal_adx":   float(r.signal_adx)   if r.signal_adx   is not None else None,
        }
        for r in rows
    ]
    return {"total": total, "trades": trades}


@router.get("/signal-log")
async def signal_log(
    days: int = Query(default=7),
    limit: int = Query(default=100),
    reason: str = Query(default=""),
    type: str = Query(default="all", description="all | entry | reject"),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    since = datetime.now(JST) - timedelta(days=days)
    q = select(SignalLog).where(SignalLog.created_at >= since)

    if type == "entry":
        q = q.where(SignalLog.direction != "NO_TRADE")
    elif type == "reject":
        q = q.where(SignalLog.direction == "NO_TRADE")

    if reason:
        q = q.where(SignalLog.reject_reason == reason)

    q = q.order_by(SignalLog.created_at.desc()).limit(limit)
    rows = (await db.execute(q)).scalars().all()

    def _ema_gap(r) -> float | None:
        if r.ema50 is not None and r.ema200 is not None and float(r.ema200) != 0:
            return round((float(r.ema50) - float(r.ema200)) / float(r.ema200) * 100, 4)
        return None

    return [
        {
            "id": r.id,
            "symbol": r.symbol,
            "timeframe": r.timeframe,
            "direction": r.direction,
            "timestamp": str(r.created_at),
            "reject_reason": r.reject_reason,
            "score": r.score,
            "price": float(r.price) if r.price is not None else None,
            "rsi":   float(r.rsi)   if r.rsi   is not None else None,
            "adx":   float(r.adx)   if r.adx   is not None else None,
            "di_plus":  float(r.di_plus)  if r.di_plus  is not None else None,
            "di_minus": float(r.di_minus) if r.di_minus is not None else None,
            "ema50":  float(r.ema50)  if r.ema50  is not None else None,
            "ema200": float(r.ema200) if r.ema200 is not None else None,
            "ema_gap": _ema_gap(r),
            "atr":    float(r.atr)    if r.atr    is not None else None,
            "htf_pass": r.htf_pass,
            "session": r.session,
        }
        for r in rows
    ]