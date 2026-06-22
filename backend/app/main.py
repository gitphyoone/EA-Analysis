import logging
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import RedirectResponse

from .database import init_db
from .routers import data, signals, trades, analytics, risk
from .config import get_settings

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","name":"%(name)s","msg":"%(message)s"}',
)
logger = logging.getLogger("ea.main")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    logger.info("Starting V19 FX Prop Desk API — env=%s", settings.environment)
    await init_db()
    yield
    logger.info("Shutting down")


settings = get_settings()

app = FastAPI(
    title="V19 FX Prop Desk",
    description="Rule-based FX trading system with risk, portfolio, news, and session engines",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.environment == "development" else ["http://localhost"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(data.router)
app.include_router(signals.router)
app.include_router(trades.router)
app.include_router(analytics.router)
app.include_router(risk.router)


@app.get("/health")
async def health():
    return {"status": "ok", "version": "1.0.0"}


@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse(url="/dashboard/")


_dashboard_dir = Path("/dashboard") if Path("/dashboard").exists() else Path(__file__).parent.parent.parent / "dashboard"
if _dashboard_dir.exists():
    app.mount("/dashboard", StaticFiles(directory=str(_dashboard_dir), html=True), name="dashboard")
