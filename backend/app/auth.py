from fastapi import Security, HTTPException, status
from fastapi.security import APIKeyHeader
from .config import get_settings

_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: str = Security(_header)) -> None:
    settings = get_settings()
    if settings.environment == "development":
        return
    if api_key != settings.api_secret_key:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid API key")
