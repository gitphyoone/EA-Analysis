"""
Journal Engine — Phase 7
Writes or updates the daily quant_journal row after each trade closes.
"""
from datetime import date, datetime, timezone
from decimal import Decimal
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
import numpy as np

from ..models.trade import TradeHistory
from ..models.journal import QuantJournal


class JournalService:
    async def update_daily(self, db: AsyncSession, target_date: date, equity_close: Decimal) -> QuantJournal:
        start = datetime(target_date.year, target_date.month, target_date.day, tzinfo=timezone.utc)
        end = datetime(target_date.year, target_date.month, target_date.day, 23, 59, 59, tzinfo=timezone.utc)

        result = await db.execute(
            select(TradeHistory)
            .where(TradeHistory.closed_at >= start, TradeHistory.closed_at <= end)
        )
        trades = result.scalars().all()

        net_pnls = [float(t.net_pnl or 0) for t in trades]
        r_mults = [float(t.r_multiple or 0) for t in trades]
        wins = [p for p in net_pnls if p > 0]
        losses = [p for p in net_pnls if p < 0]

        gross_profit = sum(wins)
        gross_loss = abs(sum(losses))
        win_rate = (len(wins) / len(trades) * 100) if trades else None
        profit_factor = (gross_profit / gross_loss) if gross_loss > 0 else None
        expectancy = (sum(r_mults) / len(r_mults)) if r_mults else None
        sharpe = float(np.mean(r_mults) / np.std(r_mults)) if len(r_mults) > 1 and np.std(r_mults) > 0 else None

        existing = await db.execute(select(QuantJournal).where(QuantJournal.date == target_date))
        row = existing.scalar_one_or_none()

        if row is None:
            row = QuantJournal(date=target_date)
            db.add(row)

        row.equity_close = equity_close
        row.daily_pnl = Decimal(str(sum(net_pnls)))
        row.trades_taken = len(trades)
        row.trades_won = len(wins)
        row.trades_lost = len(losses)
        row.win_rate = Decimal(str(round(win_rate, 4))) if win_rate is not None else None
        row.profit_factor = Decimal(str(round(profit_factor, 4))) if profit_factor is not None else None
        row.expectancy = Decimal(str(round(expectancy, 4))) if expectancy is not None else None
        row.sharpe_ratio = Decimal(str(round(sharpe, 4))) if sharpe is not None else None

        await db.commit()
        await db.refresh(row)
        return row
