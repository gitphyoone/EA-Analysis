-- V19 FX Prop Desk — Market Data EMA Migration
-- Add ema10 / ema20 columns to market_data
-- Run once:
-- docker exec -i ea_postgres psql -U ea_user -d ea_db < database/migrations/003_add_ema1020.sql

ALTER TABLE IF EXISTS market_data
ADD COLUMN IF NOT EXISTS ema10 NUMERIC(18,6);

ALTER TABLE IF EXISTS market_data
ADD COLUMN IF NOT EXISTS ema20 NUMERIC(18,6);

CREATE INDEX IF NOT EXISTS idx_market_data_ema10
ON market_data(ema10);

CREATE INDEX IF NOT EXISTS idx_market_data_ema20
ON market_data(ema20);