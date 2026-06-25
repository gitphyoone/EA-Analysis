#!/usr/bin/env python3
"""
Step 2: Inspect corrupted trade id=35 and fix it using USDJPY market_data.
"""
import asyncio
import asyncpg

DATABASE_DSN = "postgresql://ea_user:ea_pass@localhost:5432/ea_db"


async def main():
    conn = await asyncpg.connect(DATABASE_DSN)
    try:
        # ── Inspect all trades to find any with bad exit_price for JPY pairs ──
        print("=== Checking for remaining bad USDJPY trades ===")
        bad = await conn.fetch("""
            SELECT id, symbol, ticket, direction, entry_price, exit_price,
                   lot_size, gross_pnl, net_pnl, commission, swap, closed_at
            FROM trade_history
            WHERE (symbol ILIKE 'USDJPY%' OR symbol ILIKE 'GBPJPY%' OR symbol ILIKE 'EURJPY%')
              AND exit_price < 10
            ORDER BY closed_at
        """)
        if not bad:
            print("No bad JPY trades found.")
        else:
            for r in bad:
                print(f"  id={r['id']} sym={r['symbol']} ticket={r['ticket']} "
                      f"dir={r['direction']} lots={r['lot_size']} "
                      f"entry={r['entry_price']} exit={r['exit_price']} "
                      f"gross={r['gross_pnl']} closed={r['closed_at']}")

        # ── Full table dump ───────────────────────────────────────────────────
        print("\n=== All trade_history (current state) ===")
        all_t = await conn.fetch("""
            SELECT id, symbol, ticket, direction, entry_price, exit_price,
                   lot_size, gross_pnl, net_pnl, commission, swap, closed_at
            FROM trade_history ORDER BY closed_at
        """)
        for r in all_t:
            print(f"  id={r['id']:3d} {r['symbol']:10s} ticket={r['ticket']} "
                  f"{r['direction']:4s} lots={float(r['lot_size'] or 0):.2f} "
                  f"entry={float(r['entry_price'] or 0):.5f} "
                  f"exit={float(r['exit_price'] or 0):.5f} "
                  f"gross={float(r['gross_pnl'] or 0):+.2f} "
                  f"net={float(r['net_pnl'] or 0):+.2f}")

        # ── Fix bad USDJPY trades using market_data for correct rate ──────────
        if bad:
            print("\n=== Fixing corrupted USDJPY trades ===")
            async with conn.transaction():
                for r in bad:
                    tid        = r['id']
                    entry      = float(r['entry_price'])
                    lot_size   = float(r['lot_size'])
                    direction  = r['direction']
                    commission = float(r['commission'] or 0)
                    swap_val   = float(r['swap'] or 0)
                    closed_at  = r['closed_at']

                    # Get USDJPY rate from market_data nearest to close time
                    rate_row = await conn.fetchrow("""
                        SELECT close, timestamp FROM market_data
                        WHERE symbol ILIKE 'USDJPY%' AND timeframe = 'H1'
                        ORDER BY ABS(EXTRACT(EPOCH FROM (timestamp - $1)))
                        LIMIT 1
                    """, closed_at)

                    if not rate_row or float(rate_row['close']) < 10:
                        print(f"  id={tid}: No valid USDJPY rate in market_data — "
                              f"setting gross_pnl based on entry vs market rate")
                        # Fallback: use entry_price as a proxy for the close rate
                        # (assumes the trade closed near entry — conservative)
                        usdjpy_rate = entry
                    else:
                        usdjpy_rate = float(rate_row['close'])
                        print(f"  id={tid}: Using USDJPY rate={usdjpy_rate:.4f} "
                              f"from market_data at {rate_row['timestamp']}")

                    # Use market rate as exit_price (best estimate for SL/TP close)
                    correct_exit = usdjpy_rate

                    # Recalculate P&L in USD
                    if direction == 'BUY':
                        price_diff = correct_exit - entry
                    else:
                        price_diff = entry - correct_exit

                    gross_jpy = price_diff * lot_size * 100000
                    gross_usd = round(gross_jpy / usdjpy_rate, 4)
                    net_usd   = round(gross_usd - commission - abs(swap_val), 4)

                    print(f"  id={tid}: direction={direction} entry={entry:.5f} "
                          f"exit_approx={correct_exit:.5f} lots={lot_size:.2f} "
                          f"gross_usd={gross_usd:+.2f} net_usd={net_usd:+.2f}")

                    await conn.execute("""
                        UPDATE trade_history
                        SET exit_price = $1, gross_pnl = $2, net_pnl = $3
                        WHERE id = $4
                    """, correct_exit, gross_usd, net_usd, tid)

        # ── Recalculate quant_journal ─────────────────────────────────────────
        print("\n=== Recalculating quant_journal.daily_pnl ===")
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

        rows = await conn.fetch(
            "SELECT date, daily_pnl, trades_taken FROM quant_journal ORDER BY date"
        )
        print("\nFinal quant_journal:")
        for r in rows:
            print(f"  {r['date']}  daily_pnl={float(r['daily_pnl']):+.2f}  "
                  f"trades={r['trades_taken']}")

    finally:
        await conn.close()
    print("\nDone.")


if __name__ == "__main__":
    asyncio.run(main())
