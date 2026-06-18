import logging
from sqlalchemy.ext.asyncio import AsyncSession
from ..models.signal_log import SignalLog
from ..schemas.signal import SignalResult

logger = logging.getLogger("ea.signal_log")


class SignalLogService:
    async def log(self, db: AsyncSession, signal: SignalResult, session: str | None = None) -> None:
        try:
            entry = SignalLog(
                symbol=signal.symbol,
                timeframe=signal.timeframe,
                direction=signal.direction,
                score=signal.score,
                reject_reason=signal.reject_reason,
                htf_pass=signal.htf_pass,
                price=signal.current_price,
                rsi=signal.rsi,
                adx=signal.adx,
                di_plus=signal.di_plus,
                di_minus=signal.di_minus,
                ema50=signal.ema50,
                ema200=signal.ema200,
                atr=signal.atr,
                session=session,
            )
            db.add(entry)
            await db.commit()
        except Exception:
            logger.exception("Failed to write signal log — non-fatal, continuing")
            await db.rollback()
