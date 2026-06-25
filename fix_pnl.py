#!/usr/bin/env python3
"""
One-time fix: correct trade_history P&L for non-USD-quoted pairs,
then recalculate quant_journal daily_pnl.

Root cause: _calc_pnl in trades.py returned price_diff * lots * 100000
in the QUOTE currency, not in account currency (USD). For JPY pairs this
inflates values ~161x. This script divides stored values by the correct
exchange rate to convert to USD.

Run from D:/PJ/EA:
    cd backend && python ../fix_pnl.py
"""
import asyncio
import asyncpg

DATABASE_DSN = "postgresql://ea_user:ea_pass@localhost:5432/ea_db"

# Pairs where exit_price IS the rate needed to convert quote→USD
# e.g. USDJPY exit_price = JPY/USD  →  pnl_usd = pnl_jpy / exit_price
DIRECT_PAIRS = ["USDJPY", "USDCAD", "USDCHF"]

# Cross-JPY pairs: P&L is in JPY, need USDJPY rate from market_data
CROSS_JPY_PAIRS = ["GBPJPY", "EURJPY", "AUDJPY", "NZDJPY", "CADJPY", "CHFJPY"]

# USD-quoted pairs: already correct, skip
# EURUSD, GBPUSD, AUDUSD, NZDUSD, GBPUSD ...


def base_symbol(symbol: str) -> str:
    """Strip broker suffix (.y, .pro, etc) and uppercase."""
    return symbol.upper().split(".")[0]


async def main():
    conn = await asyncpg.connect(DATABASE_DSN)

    try:
        # ── Fetch all closed trades ────────────────────────────────────────
        trades = await conn.fetch("""
            SELECT id, symbol, gross_pnl, net_pnl, commission, swap,
                   exit_price, closed_at
            FROM trade_history
            ORDER BY closed_at
        """)
        print(f"Loaded {len(trades)} trade_history rows")

        fix_count = 0

        async with conn.transaction():
            for t in trades:
                tid      = t["id"]
                sym      = base_symbol(t["symbol"])
                gross    = float(t["gross_pnl"] or 0)
                comm     = float(t["commission"] or 0)
                swap_val = float(t["swap"] or 0)
                exit_px  = float(t["exit_price"])
                closed   = t["closed_at"]

                rate = None

                # Direct pairs: exit_price is the conversion divisor
                for prefix in DIRECT_PAIRS:
                    if sym.startswith(prefix):
                        if exit_px > 0:
                            rate = exit_px
                        break

                # Cross-JPY pairs: look up nearest USDJPY H1 candle
                if rate is None:
                    for prefix in CROSS_JPY_PAIRS:
                        if sym.startswith(prefix):
                            row = await conn.fetchrow("""
                                SELECT close FROM market_data
                                WHERE symbol ILIKE 'USDJPY%' AND timeframe = 'H1'
                                ORDER BY ABS(EXTRACT(EPOCH FROM (timestamp - $1)))
                                LIMIT 1
                            """, closed)
                            if row and float(row["close"]) > 0:
                                rate = float(row["close"])
                            else:
                                print(f"  WARNING: No USDJPY rate found for {t['symbol']} "
                                      f"id={tid} at {closed} — skipping")
                            break

                if rate is None:
                    continue  # USD-quoted pair or unrecognised — already correct

                new_gross = round(gross / rate, 4)
                new_net   = round(new_gross - comm - abs(swap_val), 4)

                print(f"  {t['symbol']:10s} id={tid:5d}  "
                      f"gross {gross:+12.2f} → {new_gross:+8.2f}  "
                      f"net {float(t['net_pnl'] or 0):+12.2f} → {new_net:+8.2f}  "
                      f"(÷{rate:.4f})")

                await conn.execute("""
                    UPDATE trade_history SET gross_pnl = $1, net_pnl = $2 WHERE id = $3
                """, new_gross, new_net, tid)
                fix_count += 1

        print(f"\nFixed {fix_count} trade_history rows.")

        # ── Recalculate quant_journal.daily_pnl ───────────────────────────
        print("\nRecalculating quant_journal.daily_pnl …")
        async with conn.transaction():
            await conn.execute("""
                UPDATE quant_journal qj
                SET daily_pnl = COALESCE(sub.pnl, 0)
                FROM (
                    SELECT DATE(closed_at AT TIME ZONE 'UTC') AS trade_date,
                           SUM(net_pnl) AS pnl
                    FROM trade_history
                    GROUP BY DATE(closed_at AT TIME ZONE 'UTC')
                ) sub
                WHERE qj.date = sub.trade_date
            """)

        # ── Print updated journal ─────────────────────────────────────────
        rows = await conn.fetch(
            "SELECT date, daily_pnl, trades_taken FROM quant_journal ORDER BY date"
        )
        print("\nUpdated quant_journal:")
        for r in rows:
            print(f"  {r['date']}  daily_pnl={float(r['daily_pnl']):+.2f}  "
                  f"trades={r['trades_taken']}")

    finally:
        await conn.close()

    print("\nDone — refresh the dashboard to see the corrected chart.")


if __name__ == "__main__":
    asyncio.run(main())
