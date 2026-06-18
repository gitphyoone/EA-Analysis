"""
News Engine — Phase 4
Fixes applied:
  - FIX: fail-safe — when API key missing or API call fails, BLOCK trading by default
    (original code silently disabled the news filter and allowed trading through news)
  - FIX: dynamic cache TTL — 15 min for events within 2 hours, 1 hour otherwise
  - Blackout still applies to HIGH impact events only
"""
from datetime import datetime, timedelta
from typing import Optional
import httpx
import json
import logging
from ..config import Settings

logger = logging.getLogger(__name__)

BLACKOUT_IMPACT = "HIGH"
_BLOCKED_SENTINEL = [{"_blocked": True, "reason": "NEWS_API_UNAVAILABLE"}]


class NewsEngine:
    def __init__(self, settings: Settings, redis_client=None):
        self.settings = settings
        self.redis = redis_client

    async def fetch_and_cache(self, date_str: str) -> list[dict]:
        cache_key = f"news:{date_str}"

        if self.redis:
            cached = await self.redis.get(cache_key)
            if cached:
                return json.loads(cached)

        events = await self._fetch_from_api(date_str)

        if self.redis and events and events != _BLOCKED_SENTINEL:
            ttl = self._dynamic_ttl(events)
            await self.redis.setex(cache_key, ttl, json.dumps(events, default=str))

        return events

    async def _fetch_from_api(self, date_str: str) -> list[dict]:
        if not self.settings.trading_economics_api_key:
            # FIX: was silently disabled; now returns blocked sentinel if fail_safe_block=True
            if self.settings.news_fail_safe_block:
                logger.warning("No TradingEconomics API key — blocking trading (fail-safe)")
                return _BLOCKED_SENTINEL
            logger.warning("No TradingEconomics API key — news filter disabled (fail-open)")
            return []

        url = (
            f"https://api.tradingeconomics.com/calendar"
            f"?c={self.settings.trading_economics_api_key}"
            f"&d1={date_str}&d2={date_str}"
            f"&importance=3"
        )
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(url)
                resp.raise_for_status()
                data = resp.json()
                return [
                    {
                        "event_title": e.get("Event", ""),
                        "currency": e.get("Currency", ""),
                        "impact": "HIGH",
                        "event_time": e.get("Date", ""),
                        "actual": e.get("Actual"),
                        "forecast": e.get("Forecast"),
                        "previous": e.get("Previous"),
                        "source": "TradingEconomics",
                    }
                    for e in (data if isinstance(data, list) else [])
                ]
        except Exception as exc:
            logger.error("News API fetch failed: %s — applying fail-safe block", exc)
            # FIX: API error now blocks trading instead of silently disabling filter
            return _BLOCKED_SENTINEL if self.settings.news_fail_safe_block else []

    def _dynamic_ttl(self, events: list[dict]) -> int:
        """FIX: shorter cache TTL (15 min) when an event is within 2 hours."""
        now = datetime.utcnow()
        for event in events:
            try:
                event_time = datetime.fromisoformat(str(event.get("event_time", "")))
                delta_hours = (event_time - now).total_seconds() / 3600
                if 0 < delta_hours < 2:
                    return 900   # 15 minutes
            except (ValueError, TypeError):
                continue
        return 3600  # 1 hour default

    def is_blackout(self, now: datetime, events: list[dict], affected_currencies: set[str]) -> tuple[bool, Optional[dict]]:
        # FIX: if the sentinel is present, block all trading
        if events and events[0].get("_blocked"):
            return True, events[0]

        blackout_td = timedelta(minutes=self.settings.news_blackout_minutes)
        for event in events:
            if event.get("impact") != BLACKOUT_IMPACT:
                continue
            currency = event.get("currency", "").upper()
            if currency not in affected_currencies:
                continue
            try:
                event_time = datetime.fromisoformat(str(event["event_time"]))
                if event_time.tzinfo is None:
                    from pytz import utc
                    event_time = utc.localize(event_time)
                delta = event_time - now
                if -blackout_td <= delta <= blackout_td:
                    return True, event
            except (ValueError, KeyError):
                continue
        return False, None
