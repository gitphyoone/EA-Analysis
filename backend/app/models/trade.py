from sqlalchemy import BigInteger, Integer, String, Numeric, Boolean, DateTime, func, Index
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import datetime
from decimal import Decimal
from typing import Optional


class Trade(Base):
    __tablename__ = "trades"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    ticket: Mapped[Optional[int]] = mapped_column(Integer)
    symbol: Mapped[str] = mapped_column(String(20), nullable=False)
    direction: Mapped[str] = mapped_column(String(4), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="OPEN")
    entry_price: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    stop_loss: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    take_profit: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    lot_size: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    r_target1_hit: Mapped[bool] = mapped_column(Boolean, default=False)
    r_target2_hit: Mapped[bool] = mapped_column(Boolean, default=False)
    partial_closed: Mapped[bool] = mapped_column(Boolean, default=False)
    signal_score:    Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_rsi:      Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_adx:      Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_di_plus:  Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_di_minus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_ema50:    Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    signal_ema200:   Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    account_equity: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 2))
    risk_amount: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 2))
    atr_at_entry: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    session: Mapped[Optional[str]] = mapped_column(String(20))
    opened_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    closed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        Index("idx_trades_status", "status"),
        Index("idx_trades_symbol", "symbol", "status"),
    )


class TradeHistory(Base):
    __tablename__ = "trade_history"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    ticket: Mapped[Optional[int]] = mapped_column(Integer)
    symbol: Mapped[str] = mapped_column(String(20), nullable=False)
    direction: Mapped[str] = mapped_column(String(4), nullable=False)
    entry_price: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    exit_price: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    stop_loss: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    take_profit: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    lot_size: Mapped[Decimal] = mapped_column(Numeric(10, 4), nullable=False)
    spread: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    commission: Mapped[Decimal] = mapped_column(Numeric(18, 4), default=0)
    swap: Mapped[Decimal] = mapped_column(Numeric(18, 4), default=0)
    gross_pnl: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 4))
    net_pnl: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 4))
    r_multiple: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    duration_minutes: Mapped[Optional[int]] = mapped_column(Integer)
    exit_reason: Mapped[Optional[str]] = mapped_column(String(30))
    session: Mapped[Optional[str]] = mapped_column(String(20))
    signal_score:    Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_rsi:      Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_adx:      Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_di_plus:  Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_di_minus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    signal_ema50:    Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    signal_ema200:   Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    opened_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    closed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        Index("idx_trade_history_closed", "closed_at"),
        Index("idx_trade_history_symbol", "symbol", "closed_at"),
    )
