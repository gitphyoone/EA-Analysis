"""
Trade Manager — Phase 6
Fixes applied:
  - FIX: break-even uses entry + buffer (1 pip) instead of exact entry price
         (exact entry = most common stop-hunt target; buffer avoids this)
  - FIX: added trail_from_1r option — start ATR trailing immediately after BE is set
         (original: trail only after +2R partial close, meaning +1.9R reversal = full loss)
  - Stage logic preserved: +1R → BE(+buffer) → +2R → 50% close → ATR trail
"""
from decimal import Decimal
from typing import Optional, Literal
from dataclasses import dataclass


@dataclass
class TradeManagementAction:
    action: Literal["NONE", "MOVE_BE", "PARTIAL_CLOSE", "TRAIL_STOP", "CLOSE_ALL"]
    new_sl: Optional[Decimal] = None
    close_pct: Optional[float] = None
    reason: Optional[str] = None


class TradeManager:
    def evaluate(
        self,
        direction: str,
        entry_price: Decimal,
        current_price: Decimal,
        current_sl: Decimal,
        lot_size: Decimal,
        r_target1_hit: bool,
        r_target2_hit: bool,
        partial_closed: bool,
        current_atr: Optional[Decimal] = None,
        pip_size: Decimal = Decimal("0.0001"),      # FIX: for BE buffer calculation
        be_buffer_pips: float = 1.0,                # FIX: 1 pip away from exact entry
        trail_from_1r: bool = False,                # FIX: optional early trail from +1R
    ) -> TradeManagementAction:
        sl_distance = abs(entry_price - current_sl)
        if sl_distance == 0:
            return TradeManagementAction(action="NONE")

        if direction == "BUY":
            unrealised_r = (current_price - entry_price) / sl_distance
        else:
            unrealised_r = (entry_price - current_price) / sl_distance

        # FIX: BE level is entry ± buffer, not exact entry
        be_buffer = pip_size * Decimal(str(be_buffer_pips))
        be_sl = (entry_price + be_buffer) if direction == "BUY" else (entry_price - be_buffer)

        # Stage 1: Move SL to break-even (+buffer) at +1R
        if not r_target1_hit and unrealised_r >= Decimal("1.0"):
            return TradeManagementAction(
                action="MOVE_BE",
                new_sl=be_sl,
                reason="1R_HIT_MOVE_BE",
            )

        # FIX: optional early ATR trail from +1R onwards (avoids losing all profit on +1.9R reversals)
        if trail_from_1r and r_target1_hit and not r_target2_hit and current_atr is not None:
            trail_distance = current_atr * Decimal("1.5")
            if direction == "BUY":
                new_trail_sl = current_price - trail_distance
                if new_trail_sl > current_sl:
                    return TradeManagementAction(
                        action="TRAIL_STOP",
                        new_sl=new_trail_sl,
                        reason="ATR_TRAIL_EARLY_BUY",
                    )
            else:
                new_trail_sl = current_price + trail_distance
                if new_trail_sl < current_sl:
                    return TradeManagementAction(
                        action="TRAIL_STOP",
                        new_sl=new_trail_sl,
                        reason="ATR_TRAIL_EARLY_SELL",
                    )

        # Stage 2: Close 50% at +2R
        if r_target1_hit and not r_target2_hit and unrealised_r >= Decimal("2.0") and not partial_closed:
            return TradeManagementAction(
                action="PARTIAL_CLOSE",
                close_pct=50.0,
                reason="2R_HIT_CLOSE_HALF",
            )

        # Stage 3: ATR trailing stop on remainder after partial close
        if r_target2_hit and current_atr is not None:
            trail_distance = current_atr * Decimal("1.5")
            if direction == "BUY":
                new_trail_sl = current_price - trail_distance
                if new_trail_sl > current_sl:
                    return TradeManagementAction(
                        action="TRAIL_STOP",
                        new_sl=new_trail_sl,
                        reason="ATR_TRAIL_BUY",
                    )
            else:
                new_trail_sl = current_price + trail_distance
                if new_trail_sl < current_sl:
                    return TradeManagementAction(
                        action="TRAIL_STOP",
                        new_sl=new_trail_sl,
                        reason="ATR_TRAIL_SELL",
                    )

        return TradeManagementAction(action="NONE")
