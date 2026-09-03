"""
Unit tests for engines/pretrade_engine.py — the V19.1 re-entry / daily-loss guards.
Run:  cd backend && python -m pytest tests/ -q
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from app.config import Settings
from app.engines.pretrade_engine import PretradeEngine

NOW = datetime(2026, 9, 3, 12, 0, tzinfo=timezone.utc)


def _settings(**over) -> Settings:
    base = dict(
        api_secret_key="unit_test_secret_key_1234567890",
        sl_cooldown_minutes=30,
        reentry_wait_new_candle=True,
        daily_loss_limit_pct=2.0,
    )
    base.update(over)
    return Settings(**base)


def _check(settings, *, direction="BUY", last_trades=None, candle_ts=None,
           daily_loss=Decimal(0), equity=Decimal("10000")):
    return PretradeEngine(settings).check(
        symbol="EURUSD",
        direction=direction,
        last_trades=last_trades or [],
        latest_h1_candle_ts=candle_ts if candle_ts is not None else NOW - timedelta(hours=2),
        now=NOW,
        daily_realized_loss=daily_loss,
        equity=equity,
    )


def _sl(minutes_ago, direction="BUY"):
    return {"exit_reason": "SL", "direction": direction, "closed_at": NOW - timedelta(minutes=minutes_ago)}


# ── memo §9 — SL cooldown ────────────────────────────────────────────
def test_fresh_sl_blocks():
    d = _check(_settings(), last_trades=[_sl(5)])
    assert not d.allowed and d.reason == "SL_COOLDOWN"


def test_old_sl_allows():
    d = _check(_settings(), last_trades=[_sl(45)], candle_ts=NOW - timedelta(minutes=1))
    assert d.allowed


def test_cooldown_applies_to_opposite_direction():
    d = _check(_settings(), direction="SELL", last_trades=[_sl(5, direction="BUY")])
    assert not d.allowed and d.reason == "SL_COOLDOWN"


def test_non_sl_exit_does_not_cooldown():
    tp = {"exit_reason": "TP", "direction": "BUY", "closed_at": NOW - timedelta(minutes=2)}
    assert _check(_settings(), last_trades=[tp], candle_ts=NOW - timedelta(minutes=1)).allowed


def test_cooldown_disabled():
    d = _check(_settings(sl_cooldown_minutes=0, reentry_wait_new_candle=False),
               last_trades=[_sl(1)], candle_ts=NOW - timedelta(minutes=1))
    assert d.allowed


# ── memo §11 — same-direction re-entry waits for a new H1 candle ─────
def test_same_dir_no_new_candle_blocks():
    # cooldown already elapsed, but no H1 candle has closed since the SL
    d = _check(_settings(), last_trades=[_sl(45)], candle_ts=NOW - timedelta(minutes=50))
    assert not d.allowed and d.reason == "REENTRY_WAIT_CANDLE"


def test_same_dir_with_new_candle_allows():
    d = _check(_settings(), last_trades=[_sl(45)], candle_ts=NOW - timedelta(minutes=10))
    assert d.allowed


def test_opposite_dir_not_subject_to_wait_candle():
    d = _check(_settings(), direction="SELL", last_trades=[_sl(45, direction="BUY")],
               candle_ts=NOW - timedelta(minutes=50))
    assert d.allowed


def test_wait_candle_disabled():
    d = _check(_settings(reentry_wait_new_candle=False),
               last_trades=[_sl(45)], candle_ts=NOW - timedelta(minutes=50))
    assert d.allowed


# ── memo §16 — daily realised-loss soft stop ────────────────────────
def test_daily_loss_below_limit_allows():
    assert _check(_settings(), daily_loss=Decimal("-190")).allowed          # 1.9%


def test_daily_loss_at_limit_blocks():
    d = _check(_settings(), daily_loss=Decimal("-200"))                     # 2.0%
    assert not d.allowed and d.reason == "DAILY_LOSS_LIMIT"


def test_daily_loss_positive_sign_still_blocks():
    d = _check(_settings(), daily_loss=Decimal("250"))
    assert not d.allowed and d.reason == "DAILY_LOSS_LIMIT"


def test_daily_loss_no_equity_skips():
    assert _check(_settings(), daily_loss=Decimal("-999"), equity=None).allowed


def test_clean_slate_allows():
    assert _check(_settings(), last_trades=[]).allowed
