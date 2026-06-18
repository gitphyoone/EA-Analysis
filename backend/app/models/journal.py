from sqlalchemy import BigInteger, Date, Numeric, Boolean, Text, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import date, datetime
from decimal import Decimal
from typing import Optional


class QuantJournal(Base):
    __tablename__ = "quant_journal"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    date: Mapped[date] = mapped_column(Date, nullable=False, unique=True)
    equity_open: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 2))
    equity_close: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 2))
    daily_pnl: Mapped[Decimal] = mapped_column(Numeric(18, 4), default=0)
    daily_dd_pct: Mapped[Decimal] = mapped_column(Numeric(10, 4), default=0)
    weekly_dd_pct: Mapped[Decimal] = mapped_column(Numeric(10, 4), default=0)
    monthly_dd_pct: Mapped[Decimal] = mapped_column(Numeric(10, 4), default=0)
    trades_taken: Mapped[int] = mapped_column(BigInteger, default=0)
    trades_won: Mapped[int] = mapped_column(BigInteger, default=0)
    trades_lost: Mapped[int] = mapped_column(BigInteger, default=0)
    win_rate: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    profit_factor: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    expectancy: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    sharpe_ratio: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    cb_daily_triggered: Mapped[bool] = mapped_column(Boolean, default=False)
    cb_weekly_triggered: Mapped[bool] = mapped_column(Boolean, default=False)
    cb_monthly_triggered: Mapped[bool] = mapped_column(Boolean, default=False)
    notes: Mapped[Optional[str]] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
