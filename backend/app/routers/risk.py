from fastapi import APIRouter, Depends, HTTPException
from decimal import Decimal
from typing import Optional
from pydantic import BaseModel

from ..engines.risk_engine import RiskEngine, get_fallback_pip_value, get_pip_size
from ..config import get_settings
from ..schemas.trade import PositionSize
from ..auth import verify_api_key

router = APIRouter(prefix="/risk", tags=["risk"])


class PositionSizeRequest(BaseModel):
    symbol: str
    direction: str                          # BUY | SELL
    entry_price: Decimal
    atr: Decimal
    account_equity: Decimal
    current_spread: Optional[Decimal] = None
    live_pip_value: Optional[Decimal] = None


@router.post("/position-size", response_model=PositionSize)
async def calculate_position_size(
    req: PositionSizeRequest,
    _: None = Depends(verify_api_key),
):
    settings = get_settings()
    engine = RiskEngine(settings)
    result = engine.calculate_position(
        direction=req.direction.upper(),
        symbol=req.symbol.upper(),
        entry_price=req.entry_price,
        atr=req.atr,
        account_equity=req.account_equity,
        current_spread=req.current_spread,
        live_pip_value=req.live_pip_value,
    )
    if result is None:
        raise HTTPException(422, "Position size could not be calculated — spread too wide or ATR too small")
    return result


@router.get("/settings")
async def risk_settings(_: None = Depends(verify_api_key)):
    cfg = get_settings()
    return {
        "risk_per_trade_pct": cfg.risk_per_trade_pct,
        "atr_sl_multiplier": cfg.atr_sl_multiplier,
        "atr_tp_multiplier": cfg.atr_tp_multiplier,
        "partial_close_ratio": cfg.partial_close_ratio,
        "partial_close_at_r": cfg.partial_close_at_r,
        "trail_atr_multiplier": cfg.trail_atr_multiplier,
        "trail_from_1r": cfg.trail_from_1r,
        "max_open_positions": cfg.max_open_positions,
        "atr_min_threshold": cfg.atr_min_threshold,
        "be_buffer_pips": cfg.be_buffer_pips,
        "max_spread_pips": cfg.max_spread_pips,
        "max_spread_pips_jpy": cfg.max_spread_pips_jpy,
        "max_spread_news_pips": cfg.max_spread_news_pips,
        "cb_level1_dd_pct": cfg.cb_level1_dd_pct,
        "cb_level2_dd_pct": cfg.cb_level2_dd_pct,
        "cb_level3_dd_pct": cfg.cb_level3_dd_pct,
        "cb_weekly_dd_pct": cfg.cb_weekly_dd_pct,
        "cb_monthly_dd_pct": cfg.cb_monthly_dd_pct,
        "correlation_max": cfg.correlation_max,
        "max_absolute_exposure_ratio": cfg.max_absolute_exposure_ratio,
    }
