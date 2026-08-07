import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from datetime import datetime, timezone
from decimal import Decimal

from ..database import get_db
from ..models.trade import Trade, TradeHistory
from ..schemas.trade import TradeIn, TradeOut, TradeCloseIn, TradeCloseByTicketIn, TradeUpdateIn
from ..engines.trade_manager import TradeManager
from ..services.journal_service import JournalService
from ..auth import verify_api_key

logger = logging.getLogger("ea.trades")

router = APIRouter(prefix="/trades", tags=["trades"])


@router.post("/open", response_model=TradeOut, status_code=201)
async def open_trade(
    payload: TradeIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    # FIX: guard against duplicate "open" notifications for the same ticket
    # (e.g. NotifyBackend() retried after a transient WebRequest failure, or
    # an EA restart re-sending an open it already reported). Without this, two
    # Trade rows with the same ticket+status=OPEN could exist, which lets
    # close/by-ticket "succeed" twice — once against each row — producing
    # duplicate TradeHistory entries and inflating aggregate loss figures
    # (this is what happened to tickets ...280/271/291 on 2026-08-06).
    existing = await db.execute(select(Trade).where(Trade.ticket == payload.ticket))
    if existing.scalar_one_or_none() is not None:
        raise HTTPException(409, f"Trade already exists for ticket {payload.ticket}")

    trade = Trade(
        **payload.model_dump(),
        status="OPEN",
        opened_at=datetime.now(timezone.utc),
    )
    db.add(trade)
    await db.commit()
    await db.refresh(trade)
    return trade


async def _apply_close(trade: Trade, payload, db: AsyncSession):
    # Use MT4's reported profit (account currency) when available; fallback to local calc
    # for USD-quoted pairs only (see _is_usd_quoted below) — local calc gives quote-currency
    # units which are wrong for JPY/CAD/CHF pairs (e.g. USDJPY result would be in JPY,
    # inflated ~160x).
    # MT4/MT5 report commission and swap as signed values (negative = cost,
    # positive = credit) — matches the broker statement's own net formula
    # "Commission + Swap + Profit + Taxes". Do not abs() the swap: a positive
    # swap (long-term carry credit) must be added, not subtracted.
    if payload.profit is not None:
        gross_pnl = Decimal(str(payload.profit))
    elif _is_usd_quoted(trade.symbol):
        gross_pnl = _calc_pnl(trade, payload.exit_price)
    else:
        # No broker-reported profit and the pair isn't USD-quoted (e.g. USDJPY,
        # GBPJPY, USDCAD) — _calc_pnl() would return quote-currency units
        # (JPY/CAD/...) mislabeled as USD, inflating PnL by the exchange rate
        # (~160x for JPY pairs). Leave unset rather than store a wrong-currency
        # number; SUM() in analytics ignores NULLs so totals stay correct.
        gross_pnl = None
        logger.warning(
            "No broker profit for non-USD-quoted close: ticket=%s symbol=%s — gross_pnl left NULL",
            trade.ticket, trade.symbol,
        )
    net_pnl = (
        gross_pnl + (payload.commission or Decimal(0)) + (payload.swap or Decimal(0))
        if gross_pnl is not None else None
    )
    sl_distance = abs(trade.entry_price - trade.stop_loss) if trade.stop_loss else None
    r_multiple = (
        (gross_pnl / (sl_distance * trade.lot_size * Decimal("100000"))).quantize(Decimal("0.01"))
        if gross_pnl is not None and sl_distance and sl_distance > 0 and trade.lot_size
        else None
    )
    opened_at = trade.opened_at or datetime.now(timezone.utc)
    closed_at = payload.closed_at.replace(tzinfo=timezone.utc) if payload.closed_at.tzinfo is None else payload.closed_at
    duration = int((closed_at - opened_at).total_seconds() / 60)

    history = TradeHistory(
        ticket=trade.ticket,
        symbol=trade.symbol,
        direction=trade.direction,
        entry_price=trade.entry_price,
        exit_price=payload.exit_price,
        stop_loss=trade.stop_loss,
        take_profit=trade.take_profit,
        lot_size=trade.lot_size,
        spread=payload.spread,
        commission=payload.commission or Decimal(0),
        swap=payload.swap or Decimal(0),
        gross_pnl=gross_pnl,
        net_pnl=net_pnl,
        r_multiple=r_multiple,
        duration_minutes=duration,
        exit_reason=payload.exit_reason,
        session=trade.session,
        opened_at=trade.opened_at,
        closed_at=closed_at,
        signal_score=trade.signal_score,
        signal_rsi=trade.signal_rsi,
        signal_adx=trade.signal_adx,
        signal_di_plus=trade.signal_di_plus,
        signal_di_minus=trade.signal_di_minus,
        signal_ema50=trade.signal_ema50,
        signal_ema200=trade.signal_ema200,
    )
    trade.status = "CLOSED"
    trade.closed_at = closed_at

    db.add(history)
    await db.commit()

    if payload.account_equity:
        await JournalService().update_daily(db, closed_at.date(), payload.account_equity)

    return {
        "message": "Trade closed",
        "net_pnl": float(net_pnl) if net_pnl is not None else None,
        "r_multiple": float(r_multiple or 0),
    }


@router.post("/close/{trade_id}", status_code=200)
async def close_trade(
    trade_id: int,
    payload: TradeCloseIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    trade = await db.get(Trade, trade_id)
    if trade is None:
        raise HTTPException(404, "Trade not found")
    if trade.status != "OPEN":
        raise HTTPException(409, "Trade is not open")
    return await _apply_close(trade, payload, db)


@router.post("/close/by-ticket/{ticket}", status_code=200)
async def close_trade_by_ticket(
    ticket: int,
    payload: TradeCloseByTicketIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    # FIX: row-level lock (SELECT ... FOR UPDATE) — closes the race window
    # between reading status=="OPEN" and committing status="CLOSED". Without
    # this, two near-simultaneous close requests for the same ticket (e.g.
    # from an EA restart re-sending a close it already reported) could both
    # read "OPEN" before either commits, producing two TradeHistory rows for
    # the same ticket — this is what happened to tickets ...280/271/291 on
    # 2026-08-06. The second request now blocks until the first transaction
    # commits, then re-reads status="CLOSED" and correctly 404s.
    result = await db.execute(
        select(Trade)
        .where(Trade.ticket == ticket, Trade.status == "OPEN")
        .with_for_update()
    )
    trade = result.scalar_one_or_none()
    if trade is None:
        raise HTTPException(404, f"No open trade for ticket {ticket}")

    try:
        return await _apply_close(trade, payload, db)
    except IntegrityError:
        # FIX: belt-and-suspenders for when a DB unique constraint on
        # TradeHistory.ticket is added later (not added yet — existing
        # duplicate rows need cleanup first). Once that constraint exists,
        # this catches any remaining race and treats it as an already-
        # applied close rather than erroring.
        await db.rollback()
        logger.warning("Duplicate close ignored for ticket=%s", ticket)
        return {"message": "Trade already closed (duplicate close ignored)"}


@router.post("/manage/{trade_id}")
async def manage_trade(
    trade_id: int,
    payload: TradeUpdateIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    trade = await db.get(Trade, trade_id)
    if trade is None or trade.status != "OPEN":
        raise HTTPException(404, "Open trade not found")

    mgr = TradeManager()
    action = mgr.evaluate(
        direction=trade.direction,
        entry_price=trade.entry_price,
        current_price=payload.current_price,
        current_sl=trade.stop_loss,
        lot_size=trade.lot_size,
        r_target1_hit=trade.r_target1_hit,
        r_target2_hit=trade.r_target2_hit,
        partial_closed=trade.partial_closed,
        current_atr=payload.current_atr,
    )

    if action.action == "MOVE_BE":
        trade.stop_loss = action.new_sl
        trade.r_target1_hit = True
    elif action.action == "PARTIAL_CLOSE":
        trade.r_target2_hit = True
        trade.partial_closed = True
    elif action.action == "TRAIL_STOP":
        trade.stop_loss = action.new_sl

    await db.commit()
    return {"action": action.action, "new_sl": str(action.new_sl) if action.new_sl else None, "reason": action.reason}


@router.get("/open", response_model=list[TradeOut])
async def list_open_trades(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    result = await db.execute(select(Trade).where(Trade.status == "OPEN"))
    return result.scalars().all()


def _is_usd_quoted(symbol: str) -> bool:
    # Standard 6-letter FX symbol is BASE(3)+QUOTE(3), optionally followed by a
    # broker suffix (e.g. "USDJPY.y", "EURUSDm"). _calc_pnl() below computes
    # price_diff * lot_size * 100000, which is denominated in the QUOTE
    # currency — only safe to treat as account currency (USD) when quote == USD.
    return len(symbol) >= 6 and symbol[3:6].upper() == "USD"


def _calc_pnl(trade: Trade, exit_price: Decimal) -> Decimal:
    if trade.direction == "BUY":
        price_diff = exit_price - trade.entry_price
    else:
        price_diff = trade.entry_price - exit_price
    return price_diff * (trade.lot_size or Decimal(0)) * Decimal("100000")