from sqlalchemy import BigInteger, String, Numeric, DateTime, func, UniqueConstraint, Index
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import datetime
from decimal import Decimal
from typing import Optional


class MarketData(Base):
    __tablename__ = "market_data"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    symbol: Mapped[str] = mapped_column(String(20), nullable=False)
    timeframe: Mapped[str] = mapped_column(String(10), nullable=False)
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    open: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    high: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    low: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    close: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    volume: Mapped[Optional[int]] = mapped_column(BigInteger)
    ema10: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    ema20: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    ema50: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    ema200: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    rsi14: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    adx14: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    di_plus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    di_minus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    atr14: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint("symbol", "timeframe", "timestamp"),
        Index("idx_market_data_symbol_ts", "symbol", "timeframe", "timestamp"),
    )
