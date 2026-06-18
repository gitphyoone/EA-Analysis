-- V19 FX Prop Desk — Signal Log Indicator Columns
-- Adds indicator snapshot to every logged signal evaluation.
-- Enables per-rejection detail view in the dashboard.
-- Run once: Get-Content database\migrations\004_signal_log_indicators.sql | docker exec -i ea_postgres psql -U ea_user -d ea_db

ALTER TABLE signal_log
    ADD COLUMN IF NOT EXISTS price    DECIMAL(18,6),
    ADD COLUMN IF NOT EXISTS rsi      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS adx      DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS di_plus  DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS di_minus DECIMAL(10,4),
    ADD COLUMN IF NOT EXISTS ema50    DECIMAL(18,6),
    ADD COLUMN IF NOT EXISTS ema200   DECIMAL(18,6),
    ADD COLUMN IF NOT EXISTS atr      DECIMAL(18,6);
