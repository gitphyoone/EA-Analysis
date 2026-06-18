from sqlalchemy import Integer, Numeric, DateTime
from sqlalchemy.orm import Mapped, mapped_column
from ..database import Base
from datetime import datetime
from decimal import Decimal
from typing import Optional


class AccountSnapshot(Base):
    __tablename__ = "account_snapshots"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    equity: Mapped[Decimal] = mapped_column(Numeric(18, 2), nullable=False)
    balance: Mapped[Optional[Decimal]] = mapped_column(Numeric(18, 2))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
