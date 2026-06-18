from sqlalchemy import BigInteger, SmallInteger, Numeric, String, Boolean, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import datetime
from decimal import Decimal
from typing import Optional


class SignalLog(Base):
    __tablename__ = "signal_log"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    symbol: Mapped[str] = mapped_column(String(20), nullable=False)
    timeframe: Mapped[str] = mapped_column(String(10), nullable=False)
    direction: Mapped[str] = mapped_column(String(10), nullable=False)
    score: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    reject_reason: Mapped[Optional[str]] = mapped_column(String(50))
    htf_pass: Mapped[Optional[bool]] = mapped_column(Boolean)
    price: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    rsi: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    adx: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    di_plus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    di_minus: Mapped[Optional[Decimal]] = mapped_column(Numeric(10, 4))
    ema50: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    ema200: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    atr: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 6))
    session: Mapped[Optional[str]] = mapped_column(String(20))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
