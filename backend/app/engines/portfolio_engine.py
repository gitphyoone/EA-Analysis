"""
Portfolio Engine — Phase 3
Fixes applied:
  - FIX: removed redundant currency-overlap block (correlation filter already handles this;
         overlap rule was too strict and blocked valid trades e.g. EURUSD + GBPUSD in USD trend)
  - FIX: exposure calculation now correctly handles USD-base pairs (USDJPY etc.)
         old formula: lot × 100,000 × 150 = 15,000,000 JPY compared against USD equity — meaningless
         new formula: USD-quote → notional = lots × 100,000 × price
                      USD-base  → notional = lots × 100,000
                      cross     → conservative: lots × 100,000
  - Correlation window now reads from config (default changed to 60 — was 20)
"""
from decimal import Decimal
from typing import Optional
import numpy as np
from ..config import Settings


class PortfolioEngine:
    def __init__(self, settings: Settings):
        self.settings = settings

    def can_open_trade(
        self,
        new_symbol: str,
        open_positions: list[dict],
        equity: Decimal,
        price_histories: Optional[dict[str, list[float]]] = None,
    ) -> tuple[bool, str]:
        cfg = self.settings

        # Max concurrent positions
        if len(open_positions) >= cfg.max_open_positions:
            return False, "MAX_POSITIONS_REACHED"

        # FIX: currency-overlap block removed — correlation filter is the sole diversity guard
        # (original dual-rule was too aggressive: EURUSD blocked GBPUSD in a USD trend)

        # FIX: exposure limit with correct USD normalisation
        total_notional = sum(
            self._notional_usd(pos.get("symbol", ""), pos.get("lot_size", 0), pos.get("entry_price", 1))
            for pos in open_positions
        )
        max_exposure = equity * Decimal(str(cfg.max_absolute_exposure_ratio))
        if total_notional >= max_exposure:
            return False, "EXPOSURE_LIMIT"

        # Correlation filter (window = config, default 60)
        if price_histories and len(open_positions) > 0 and new_symbol in price_histories:
            new_series = price_histories.get(new_symbol, [])
            window = cfg.correlation_window
            for pos in open_positions:
                pos_sym = pos["symbol"]
                if pos_sym not in price_histories:
                    continue
                pos_series = price_histories[pos_sym]
                n = min(len(new_series), len(pos_series), window)
                if n < 10:
                    continue
                corr = float(np.corrcoef(new_series[-n:], pos_series[-n:])[0, 1])
                if abs(corr) > cfg.correlation_max:
                    return False, f"HIGH_CORRELATION_{pos_sym}_{corr:.2f}"

        return True, "OK"

    def _notional_usd(self, symbol: str, lots, entry_price) -> Decimal:
        """FIX: correct USD normalisation per pair type."""
        lots_d = Decimal(str(lots))
        price_d = Decimal(str(entry_price))
        units = lots_d * Decimal("100000")

        s = symbol.upper().replace("/", "")
        if len(s) < 6:
            return units  # unknown format, conservative

        base = s[:3]
        quote = s[3:6]

        if quote == "USD":
            # EURUSD, GBPUSD, AUDUSD — notional in USD = units × price
            return units * price_d
        elif base == "USD":
            # USDJPY, USDCAD — base is USD; 1 unit = 1 USD regardless of quote rate
            return units
        else:
            # Cross pairs (EURJPY, GBPJPY, EURGBP) — approximate as USD notional = units
            # In production: multiply by USD/base conversion rate for precision
            return units
