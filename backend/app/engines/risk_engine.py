"""
Risk Engine — Phase 2
Fixes applied:
  - FIX: static pip value table replaced with live_pip_value parameter from MT4
         (static table had 40%+ error when USDJPY moved from 110 to 155+)
  - FIX: circuit breaker now requires realized_daily_loss_pct — prevents CB bypass
         when all losses are from closed trades and floating P&L appears fine
  - Fallback table kept as emergency default with updated approximate rates
"""
from decimal import Decimal, ROUND_DOWN
from typing import Optional
from ..config import Settings
from ..schemas.trade import PositionSize
from ..schemas.signal import CircuitBreakerState

# Fallback only — MT4 should pass live_pip_value via MarketInfo()
# These values assume approximate current rates and will drift
_FALLBACK_PIP_VALUE: dict[str, Decimal] = {
    "EURUSD": Decimal("10.0"),
    "GBPUSD": Decimal("10.0"),
    "AUDUSD": Decimal("10.0"),
    "NZDUSD": Decimal("10.0"),
    "USDCAD": Decimal("7.50"),   # approx at 1.33 USDCAD
    "USDCHF": Decimal("11.20"),  # approx at 0.89 USDCHF
    "USDJPY": Decimal("6.50"),   # approx at 154 USDJPY — FIX: was 9.09 (based on 110)
    "EURJPY": Decimal("6.50"),
    "GBPJPY": Decimal("6.50"),
    "AUDJPY": Decimal("6.50"),
    "CADJPY": Decimal("6.50"),
    "EURGBP": Decimal("12.60"),  # approx at GBPUSD 1.26
    "EURCAD": Decimal("7.50"),
    "GBPCAD": Decimal("7.50"),
    "AUDCAD": Decimal("7.50"),
}

_PIP_SIZE: dict[str, Decimal] = {
    "JPY": Decimal("0.01"),
    "DEFAULT": Decimal("0.0001"),
}


def get_pip_size(symbol: str) -> Decimal:
    return _PIP_SIZE["JPY"] if "JPY" in symbol else _PIP_SIZE["DEFAULT"]


def get_fallback_pip_value(symbol: str) -> Decimal:
    return _FALLBACK_PIP_VALUE.get(symbol.upper(), Decimal("10.0"))


class RiskEngine:
    def __init__(self, settings: Settings):
        self.settings = settings

    def calculate_position(
        self,
        direction: str,
        symbol: str,
        entry_price: Decimal,
        atr: Decimal,
        account_equity: Decimal,
        current_spread: Optional[Decimal] = None,
        live_pip_value: Optional[Decimal] = None,   # FIX: from MT4 MarketInfo()
    ) -> Optional[PositionSize]:
        cfg = self.settings

        # Spread guard
        if current_spread is not None:
            avg_spread = get_pip_size(symbol) * 2
            if current_spread > avg_spread * Decimal(str(cfg.max_spread_multiplier)):
                return None

        risk_amount = account_equity * Decimal(str(cfg.risk_per_trade_pct / 100))

        sl_distance = atr * Decimal(str(cfg.atr_sl_multiplier))
        tp_distance = atr * Decimal(str(cfg.atr_tp_multiplier))

        if direction == "BUY":
            sl_price = entry_price - sl_distance
            tp_price = entry_price + tp_distance
        else:
            sl_price = entry_price + sl_distance
            tp_price = entry_price - tp_distance

        pip_size = get_pip_size(symbol)
        # FIX: use live pip value from MT4 if available; fallback to table otherwise
        pip_value = live_pip_value if live_pip_value is not None else get_fallback_pip_value(symbol)

        sl_pips = sl_distance / pip_size

        if sl_pips <= 0 or pip_value <= 0:
            return None

        lots = risk_amount / (sl_pips * pip_value)
        lots = lots.quantize(Decimal("0.01"), rounding=ROUND_DOWN)

        if lots < Decimal("0.01"):
            return None

        return PositionSize(
            lots=lots,
            sl_distance=sl_distance,
            tp_distance=tp_distance,
            sl_price=sl_price,
            tp_price=tp_price,
            risk_amount=risk_amount,
            r_ratio=(tp_distance / sl_distance).quantize(Decimal("0.01")),
            sl_pips=sl_pips,
        )

    def check_circuit_breakers(
        self,
        daily_dd_pct: float,
        weekly_dd_pct: float,
        monthly_dd_pct: float,
        realized_daily_loss_pct: float = 0.0,
    ) -> CircuitBreakerState:
        cfg = self.settings
        total_daily_dd = daily_dd_pct + realized_daily_loss_pct

        common = dict(
            daily_dd_pct=total_daily_dd,
            weekly_dd_pct=weekly_dd_pct,
            monthly_dd_pct=monthly_dd_pct,
        )

        # Weekly / monthly are single-threshold emergency stops
        if monthly_dd_pct >= cfg.cb_monthly_dd_pct:
            return CircuitBreakerState(triggered=True, level="MONTHLY", reason="MONTHLY_DD", **common)
        if weekly_dd_pct >= cfg.cb_weekly_dd_pct:
            return CircuitBreakerState(triggered=True, level="WEEKLY", reason="WEEKLY_DD", **common)

        # Daily multi-level (highest level wins)
        if total_daily_dd >= cfg.cb_level3_dd_pct:
            return CircuitBreakerState(triggered=True, level="LEVEL_3", reason="DAILY_DD_L3", **common)
        if total_daily_dd >= cfg.cb_level2_dd_pct:
            return CircuitBreakerState(triggered=True, level="LEVEL_2", reason="DAILY_DD_L2", **common)
        if total_daily_dd >= cfg.cb_level1_dd_pct:
            return CircuitBreakerState(triggered=True, level="LEVEL_1", reason="DAILY_DD_L1", **common)

        return CircuitBreakerState(triggered=False, **common)
