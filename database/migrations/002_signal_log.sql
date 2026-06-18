-- V19 FX Prop Desk — Signal Log (v2.1)
-- Stores every signal evaluation (BUY / SELL / NO_TRADE) for reject analytics.
-- Run once: docker exec -i ea_postgres psql -U ea_user -d ea_db < database/migrations/002_signal_log.sql

CREATE TABLE IF NOT EXISTS signal_log (
    id            BIGSERIAL PRIMARY KEY,
    symbol        VARCHAR(20)  NOT NULL,
    timeframe     VARCHAR(10)  NOT NULL,
    direction     VARCHAR(10)  NOT NULL,
    score         SMALLINT     NOT NULL,
    reject_reason VARCHAR(50),
    htf_pass      BOOLEAN,
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signal_log_created  ON signal_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_signal_log_reject   ON signal_log(reject_reason, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_signal_log_symbol   ON signal_log(symbol, created_at DESC);
