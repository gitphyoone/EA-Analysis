-- V19 FX Prop Desk — Signal Reasoning Columns (v2.03)
-- Adds signal indicator values captured at trade-open time.
-- Enables post-trade score calibration and RSI/ADX pattern analysis.
-- Run once: docker exec -i ea_postgres psql -U ea_user -d ea_db < database/migrations/003_signal_reasoning.sql

-- ─────────────────────────────────────────
-- trades
-- ─────────────────────────────────────────
ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS signal_rsi      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_adx      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_di_plus  DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_di_minus DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_ema50    DECIMAL(18,6),
    ADD COLUMN IF NOT EXISTS signal_ema200   DECIMAL(18,6);

-- signal_score already exists in trades from 001_init.sql;
-- add only if missing (e.g. older installs that predated the column).
ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS signal_score DECIMAL(10,4);

-- ─────────────────────────────────────────
-- trade_history
-- ─────────────────────────────────────────
ALTER TABLE trade_history
    ADD COLUMN IF NOT EXISTS signal_score    DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_rsi      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_adx      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_di_plus  DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_di_minus DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS signal_ema50    DECIMAL(18,6),
    ADD COLUMN IF NOT EXISTS signal_ema200   DECIMAL(18,6);

-- Index: score calibration query — win rate grouped by score bucket
CREATE INDEX IF NOT EXISTS idx_th_signal_score
    ON trade_history(signal_score, exit_reason);

-- Index: RSI-range analysis query
CREATE INDEX IF NOT EXISTS idx_th_signal_rsi
    ON trade_history(signal_rsi, exit_reason);
