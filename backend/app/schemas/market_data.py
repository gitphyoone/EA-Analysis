from pydantic import BaseModel, field_validator
from datetime import datetime
from typing import Optional
from decimal import Decimal


class MarketDataIn(BaseModel):
    symbol: str
    timeframe: str
    timestamp: datetime
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Optional[int] = None
    ema10: Optional[Decimal] = None
    ema20: Optional[Decimal] = None
    ema50: Optional[Decimal] = None
    ema200: Optional[Decimal] = None
    rsi14: Optional[Decimal] = None
    adx14: Optional[Decimal] = None
    di_plus: Optional[Decimal] = None
    di_minus: Optional[Decimal] = None
    atr14: Optional[Decimal] = None

    @field_validator("symbol")
    @classmethod
    def symbol_upper(cls, v: str) -> str:
        return v.upper()

    @field_validator("timeframe")
    @classmethod
    def timeframe_upper(cls, v: str) -> str:
        return v.upper()


class MarketDataOut(MarketDataIn):
    id: int
    created_at: datetime

    model_config = {"from_attributes": True}
