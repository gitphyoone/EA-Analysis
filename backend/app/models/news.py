from sqlalchemy import BigInteger, String, DateTime, func, UniqueConstraint, Index
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import datetime
from typing import Optional


class NewsEvent(Base):
    __tablename__ = "news_events"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    event_title: Mapped[str] = mapped_column(String(255), nullable=False)
    currency: Mapped[str] = mapped_column(String(10), nullable=False)
    impact: Mapped[str] = mapped_column(String(10), nullable=False)
    event_time: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    actual: Mapped[Optional[str]] = mapped_column(String(50))
    forecast: Mapped[Optional[str]] = mapped_column(String(50))
    previous: Mapped[Optional[str]] = mapped_column(String(50))
    source: Mapped[Optional[str]] = mapped_column(String(50))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    __table_args__ = (
        UniqueConstraint("event_title", "currency", "event_time"),
        Index("idx_news_time", "event_time", "impact"),
        Index("idx_news_currency", "currency", "event_time"),
    )
