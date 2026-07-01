from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, insert
from sqlalchemy.dialects.postgresql import insert as pg_insert
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel
from ..database import get_db
from ..models.market_data import MarketData
from ..models.account import AccountSnapshot
from ..schemas.market_data import MarketDataIn, MarketDataOut
from ..auth import verify_api_key

router = APIRouter(prefix="/data", tags=["market-data"])


@router.post("/candle", response_model=MarketDataOut, status_code=201)
async def ingest_candle(
    payload: MarketDataIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    data = payload.model_dump()
    stmt = (
        pg_insert(MarketData)
        .values(**data)
        .on_conflict_do_update(
            index_elements=["symbol", "timeframe", "timestamp"],
            set_={k: v for k, v in data.items() if k not in ("symbol", "timeframe", "timestamp")},
        )
        .returning(MarketData)
    )
    result = await db.execute(stmt)
    await db.commit()
    row = result.scalar_one()
    return row


class AccountSnapshotIn(BaseModel):
    equity: Decimal
    balance: Optional[Decimal] = None


@router.post("/account", status_code=200)
async def ingest_account_snapshot(
    payload: AccountSnapshotIn,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    snapshot = await db.get(AccountSnapshot, 1)
    now = datetime.now(timezone.utc)
    if snapshot:
        snapshot.equity = payload.equity
        snapshot.balance = payload.balance
        snapshot.updated_at = now
    else:
        db.add(AccountSnapshot(id=1, equity=payload.equity, balance=payload.balance, updated_at=now))
    await db.commit()
    return {"equity": float(payload.equity)}


@router.get("/candles/{symbol}", response_model=list[MarketDataOut])
async def get_candles(
    symbol: str,
    timeframe: str = "H1",
    limit: int = 200,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(verify_api_key),
):
    stmt = (
        select(MarketData)
        .where(MarketData.symbol == symbol.upper(), MarketData.timeframe == timeframe.upper())
        .order_by(MarketData.timestamp.desc())
        .limit(limit)
    )
    result = await db.execute(stmt)
    rows = result.scalars().all()
    return list(reversed(rows))
