-- V19 FX Prop Desk — Database Schema (consolidated baseline)
-- Run once on first boot (docker-entrypoint-initdb.d)
-- Supersedes 002_signal_log.sql, 003_signal_reasoning.sql,
-- 004_signal_log_indicators.sql, 005_signal_log_session.sql,
-- migrate_add_ema1020.sql — all folded into this single initial schema.

-- ─────────────────────────────────────────
-- Market Data
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS market_data (
    id          BIGSERIAL PRIMARY KEY,
    symbol      VARCHAR(20)    NOT NULL,
    timeframe   VARCHAR(10)    NOT NULL,
    timestamp   TIMESTAMPTZ    NOT NULL,
    open        DECIMAL(18,6)  NOT NULL,
    high        DECIMAL(18,6)  NOT NULL,
    low         DECIMAL(18,6)  NOT NULL,
    close       DECIMAL(18,6)  NOT NULL,
    volume      BIGINT,
    ema10       DECIMAL(18,6),
    ema20       DECIMAL(18,6),
    ema50       DECIMAL(18,6),
    ema200      DECIMAL(18,6),
    rsi14       DECIMAL(10,4),
    adx14       DECIMAL(10,4),
    di_plus     DECIMAL(10,4),
    di_minus    DECIMAL(10,4),
    atr14       DECIMAL(18,6),
    created_at  TIMESTAMPTZ    DEFAULT NOW(),
    UNIQUE(symbol, timeframe, timestamp)
);

CREATE INDEX IF NOT EXISTS idx_market_data_symbol_ts ON market_data(symbol, timeframe, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_market_data_ema10 ON market_data(ema10);
CREATE INDEX IF NOT EXISTS idx_market_data_ema20 ON market_data(ema20);

-- ─────────────────────────────────────────
-- Active Trades
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trades (
    id                  BIGSERIAL PRIMARY KEY,
    ticket              INTEGER,
    symbol              VARCHAR(20)   NOT NULL,
    direction           VARCHAR(4)    NOT NULL CHECK (direction IN ('BUY','SELL')),
    status              VARCHAR(20)   NOT NULL DEFAULT 'OPEN'
                                      CHECK (status IN ('OPEN','CLOSED','PENDING','REJECTED')),
    entry_price         DECIMAL(18,6),
    stop_loss           DECIMAL(18,6),
    take_profit         DECIMAL(18,6),
    lot_size            DECIMAL(10,4),
    r_target1_hit       BOOLEAN       DEFAULT FALSE,
    r_target2_hit       BOOLEAN       DEFAULT FALSE,
    partial_closed      BOOLEAN       DEFAULT FALSE,
    signal_score        DECIMAL(10,4),
    signal_rsi          DECIMAL(10,4),
    signal_adx          DECIMAL(10,4),
    signal_di_plus      DECIMAL(10,4),
    signal_di_minus     DECIMAL(10,4),
    signal_ema50        DECIMAL(18,6),
    signal_ema200       DECIMAL(18,6),
    account_equity      DECIMAL(18,2),
    risk_amount         DECIMAL(18,2),
    atr_at_entry        DECIMAL(18,6),
    session             VARCHAR(20),
    opened_at           TIMESTAMPTZ,
    closed_at           TIMESTAMPTZ,
    created_at          TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trades_status ON trades(status);
CREATE INDEX IF NOT EXISTS idx_trades_symbol ON trades(symbol, status);

-- ─────────────────────────────────────────
-- Trade History (closed trades journal)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trade_history (
    id               BIGSERIAL PRIMARY KEY,
    ticket           INTEGER,
    symbol           VARCHAR(20)   NOT NULL,
    direction        VARCHAR(4)    NOT NULL,
    entry_price      DECIMAL(18,6) NOT NULL,
    exit_price       DECIMAL(18,6) NOT NULL,
    stop_loss        DECIMAL(18,6),
    take_profit      DECIMAL(18,6),
    lot_size         DECIMAL(10,4) NOT NULL,
    spread           DECIMAL(10,4),
    commission       DECIMAL(18,4) DEFAULT 0,
    swap             DECIMAL(18,4) DEFAULT 0,
    gross_pnl        DECIMAL(18,4),
    net_pnl          DECIMAL(18,4),
    r_multiple       DECIMAL(10,4),
    duration_minutes INTEGER,
    exit_reason      VARCHAR(30)   CHECK (exit_reason IN ('TP','SL','TRAILING','PARTIAL','MANUAL','CB')),
    session          VARCHAR(20),
    signal_score     DECIMAL(10,4),
    signal_rsi       DECIMAL(10,4),
    signal_adx       DECIMAL(10,4),
    signal_di_plus   DECIMAL(10,4),
    signal_di_minus  DECIMAL(10,4),
    signal_ema50     DECIMAL(18,6),
    signal_ema200    DECIMAL(18,6),
    opened_at        TIMESTAMPTZ,
    closed_at        TIMESTAMPTZ,
    created_at       TIMESTAMPTZ   DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trade_history_symbol ON trade_history(symbol, closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_history_closed ON trade_history(closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_th_signal_score ON trade_history(signal_score, exit_reason);
CREATE INDEX IF NOT EXISTS idx_th_signal_rsi ON trade_history(signal_rsi, exit_reason);

-- ─────────────────────────────────────────
-- Quant Journal (daily summary)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quant_journal (
    id                      BIGSERIAL PRIMARY KEY,
    date                    DATE          NOT NULL UNIQUE,
    equity_open             DECIMAL(18,2),
    equity_close            DECIMAL(18,2),
    daily_pnl               DECIMAL(18,4) DEFAULT 0,
    daily_dd_pct            DECIMAL(10,4) DEFAULT 0,
    weekly_dd_pct           DECIMAL(10,4) DEFAULT 0,
    monthly_dd_pct          DECIMAL(10,4) DEFAULT 0,
    trades_taken            INTEGER       DEFAULT 0,
    trades_won              INTEGER       DEFAULT 0,
    trades_lost             INTEGER       DEFAULT 0,
    win_rate                DECIMAL(10,4),
    profit_factor           DECIMAL(10,4),
    expectancy              DECIMAL(10,4),
    sharpe_ratio            DECIMAL(10,4),
    cb_daily_triggered      BOOLEAN       DEFAULT FALSE,
    cb_weekly_triggered     BOOLEAN       DEFAULT FALSE,
    cb_monthly_triggered    BOOLEAN       DEFAULT FALSE,
    notes                   TEXT,
    created_at              TIMESTAMPTZ   DEFAULT NOW()
);

-- ─────────────────────────────────────────
-- News Events
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS news_events (
    id          BIGSERIAL PRIMARY KEY,
    event_title VARCHAR(255)  NOT NULL,
    currency    VARCHAR(10)   NOT NULL,
    impact      VARCHAR(10)   NOT NULL CHECK (impact IN ('HIGH','MEDIUM','LOW')),
    event_time  TIMESTAMPTZ   NOT NULL,
    actual      VARCHAR(50),
    forecast    VARCHAR(50),
    previous    VARCHAR(50),
    source      VARCHAR(50),
    created_at  TIMESTAMPTZ   DEFAULT NOW(),
    UNIQUE(event_title, currency, event_time)
);

CREATE INDEX IF NOT EXISTS idx_news_time ON news_events(event_time, impact);
CREATE INDEX IF NOT EXISTS idx_news_currency ON news_events(currency, event_time);

-- ─────────────────────────────────────────
-- Signal Log (every BUY / SELL / NO_TRADE evaluation)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS signal_log (
    id            BIGSERIAL PRIMARY KEY,
    symbol        VARCHAR(20)  NOT NULL,
    timeframe     VARCHAR(10)  NOT NULL,
    direction     VARCHAR(10)  NOT NULL,
    score         SMALLINT     NOT NULL,
    reject_reason VARCHAR(50),
    htf_pass      BOOLEAN,
    price         DECIMAL(18,6),
    rsi           DECIMAL(10,4),
    adx           DECIMAL(10,4),
    di_plus       DECIMAL(10,4),
    di_minus      DECIMAL(10,4),
    ema50         DECIMAL(18,6),
    ema200        DECIMAL(18,6),
    atr           DECIMAL(18,6),
    session       VARCHAR(20),
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signal_log_created ON signal_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_signal_log_reject  ON signal_log(reject_reason, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_signal_log_symbol  ON signal_log(symbol, created_at DESC);
