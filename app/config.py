"""
Configuration module for KitchenKeep.

Loads settings from environment variables and .env files.
Automatically detects whether running in production (/opt/kitchenkeep exists)
or development mode, falling back to local paths when appropriate.
"""

import os
from pathlib import Path

from pydantic_settings import BaseSettings
from pydantic import Field


# Detect whether we're running in production (install path exists)
_PROD_DIR = Path("/opt/kitchenkeep")
_IS_PROD = _PROD_DIR.exists()

# Determine .env file location: production first, then local for dev
_ENV_FILE: str
if (_PROD_DIR / ".env").exists():
    _ENV_FILE = str(_PROD_DIR / ".env")
elif Path(".env").exists():
    _ENV_FILE = ".env"
else:
    _ENV_FILE = ".env"  # pydantic-settings will silently skip if missing


class Settings(BaseSettings):
    """Application settings loaded from environment variables.

    Production .env lives at /opt/kitchenkeep/.env.
    For local development, place a .env file in the project root and set
    DATABASE_URL=sqlite:///./data/recipes.db.
    """

    database_url: str = Field(
        default=(
            "sqlite:////opt/kitchenkeep/data/recipes.db"
            if _IS_PROD
            else "sqlite:///./data/recipes.db"
        ),
        description="SQLAlchemy-style database URL for SQLite",
    )

    ollama_base_url: str = Field(
        default="http://localhost:11434",
        description="Base URL for the local Ollama API",
    )

    ollama_model: str = Field(
        default="mistral",
        description="Ollama model name used for recipe extraction",
    )

    app_port: int = Field(
        default=8000,
        description="Port the uvicorn server listens on",
    )

    app_host: str = Field(
        default="0.0.0.0",
        description="Host interface the uvicorn server binds to",
    )

    debug: bool = Field(
        default=False,
        description="Enable FastAPI debug mode — never use in production",
    )

    class Config:
        env_file = _ENV_FILE
        env_file_encoding = "utf-8"
        # Allow extra env vars without raising errors
        extra = "ignore"


# Module-level singleton — import this everywhere
settings = Settings()
