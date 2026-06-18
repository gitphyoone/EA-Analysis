"""
Session Engine — Phase 5
Fixes applied:
  - DST-aware London / NY hours (as before)
  - FIX: added is_friday_close() — no new trades + close all on Friday ≥ 20:00 UTC
  - FIX: added should_close_all() — covers Friday close + weekend gap protection
  - FIX: enable_session_filter toggle — False bypasses London/NY gate (demo/backtest);
         weekend + Friday close always blocked regardless of the flag
"""
from datetime import datetime, time
from typing import Literal
import pytz

SessionName = Literal["LONDON", "NEW_YORK", "OVERLAP", "OFF_SESSION"]

LONDON_TZ = pytz.timezone("Europe/London")
NY_TZ = pytz.timezone("America/New_York")
UTC = pytz.utc


def _london_hours(dt_utc: datetime) -> tuple[time, time]:
    london_now = dt_utc.astimezone(LONDON_TZ)
    if london_now.dst().seconds > 0:        # BST (UTC+1), summer
        return time(7, 0), time(16, 0)
    return time(8, 0), time(17, 0)          # GMT (UTC+0), winter


def _ny_hours(dt_utc: datetime) -> tuple[time, time]:
    ny_now = dt_utc.astimezone(NY_TZ)
    if ny_now.dst().seconds > 0:            # EDT (UTC-4), summer
        return time(13, 0), time(21, 0)
    return time(14, 0), time(22, 0)         # EST (UTC-5), winter


class SessionEngine:
    def __init__(self, friday_close_hour_utc: int = 20, enable_session_filter: bool = False):
        self.friday_close_hour = friday_close_hour_utc
        self.enable_session_filter = enable_session_filter

    def get_session(self, dt_utc: datetime) -> SessionName:
        if dt_utc.tzinfo is None:
            dt_utc = UTC.localize(dt_utc)

        t = dt_utc.time()
        lon_open, lon_close = _london_hours(dt_utc)
        ny_open, ny_close = _ny_hours(dt_utc)

        in_london = lon_open <= t < lon_close
        in_ny = ny_open <= t < ny_close

        if in_london and in_ny:
            return "OVERLAP"
        if in_london:
            return "LONDON"
        if in_ny:
            return "NEW_YORK"
        return "OFF_SESSION"

    def is_tradeable(self, dt_utc: datetime) -> bool:
        if self.is_weekend(dt_utc):
            return False
        if self.is_friday_close(dt_utc):
            return False
        if not self.enable_session_filter:
            return True
        return self.get_session(dt_utc) != "OFF_SESSION"

    def is_friday_close(self, dt_utc: datetime) -> bool:
        """Friday ≥ friday_close_hour UTC — no new trades, start closing positions."""
        if dt_utc.tzinfo is None:
            dt_utc = UTC.localize(dt_utc)
        return dt_utc.weekday() == 4 and dt_utc.hour >= self.friday_close_hour

    def is_weekend(self, dt_utc: datetime) -> bool:
        """Saturday and Sunday — market closed."""
        if dt_utc.tzinfo is None:
            dt_utc = UTC.localize(dt_utc)
        return dt_utc.weekday() in (5, 6)

    def should_close_all(self, dt_utc: datetime) -> bool:
        """True when all open positions should be closed for risk management."""
        return self.is_friday_close(dt_utc) or self.is_weekend(dt_utc)
