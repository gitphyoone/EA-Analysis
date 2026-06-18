from pydantic import BaseModel
from typing import Literal, Optional
from decimal import Decimal
from datetime import datetime


class PositionSize(BaseModel):
    lots: Decimal
    sl_distance: Decimal
    tp_distance: Decimal
    sl_price: Decimal
    tp_price: Decimal
    risk_amount: Decimal
    r_ratio: Decimal
    sl_pips: Decimal


class TradeIn(BaseModel):
    ticket: Optional[int] = None
    symbol: str
    direction: Literal["BUY", "SELL"]
    entry_price: Decimal
    stop_loss: Decimal
    take_profit: Decimal
    lot_size: Decimal
    account_equity: Decimal
    risk_amount: Decimal
    atr_at_entry:    Optional[Decimal] = None
    session:         Optional[str] = None
    signal_score:    Optional[Decimal] = None
    signal_rsi:      Optional[Decimal] = None
    signal_adx:      Optional[Decimal] = None
    signal_di_plus:  Optional[Decimal] = None
    signal_di_minus: Optional[Decimal] = None
    signal_ema50:    Optional[Decimal] = None
    signal_ema200:   Optional[Decimal] = None


class TradeOut(TradeIn):
    id: int
    status: str
    r_target1_hit: bool
    r_target2_hit: bool
    partial_closed: bool
    opened_at: Optional[datetime]
    closed_at: Optional[datetime]
    created_at: datetime

    model_config = {"from_attributes": True}


class TradeCloseIn(BaseModel):
    ticket: int
    exit_price: Decimal
    spread: Optional[Decimal] = None
    commission: Optional[Decimal] = None
    swap: Optional[Decimal] = None
    exit_reason: Literal["TP", "SL", "TRAILING", "PARTIAL", "MANUAL", "CB"]
    closed_at: datetime
    account_equity: Optional[Decimal] = None  # MT4 sends current balance on close


class TradeCloseByTicketIn(BaseModel):
    exit_price: Decimal
    spread: Optional[Decimal] = None
    commission: Optional[Decimal] = None
    swap: Optional[Decimal] = None
    exit_reason: Literal["TP", "SL", "TRAILING", "PARTIAL", "MANUAL", "CB"]
    closed_at: datetime
    account_equity: Optional[Decimal] = None


class TradeUpdateIn(BaseModel):
    current_price: Decimal
    account_equity: Decimal
    current_atr: Optional[Decimal] = None
