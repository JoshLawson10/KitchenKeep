"""
Database engine and session factory for KitchenKeep.

Uses SQLModel on top of SQLAlchemy with a SQLite backend.
The engine is created once at module import time; session lifecycle is
managed via the get_session() FastAPI dependency.
"""

import logging
from pathlib import Path

from sqlmodel import SQLModel, Session, create_engine

from app.config import settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Engine setup
# ---------------------------------------------------------------------------

# Extract path from sqlite URL and ensure directory exists before connecting.
# SQLite URL format: sqlite:////absolute/path  or  sqlite:///relative/path
_db_url = settings.database_url
_db_path_str = _db_url.replace("sqlite:///", "")  # works for both // and ////
_db_path = Path(_db_path_str)

if _db_path.parent and not _db_path.parent.exists():
    logger.info("Creating database directory: %s", _db_path.parent)
    _db_path.parent.mkdir(parents=True, exist_ok=True)

# connect_args: SQLite needs check_same_thread=False when used with FastAPI
engine = create_engine(
    _db_url,
    echo=settings.debug,  # SQL echo only in debug mode
    connect_args={"check_same_thread": False},
)

logger.info("Database engine initialised: %s", _db_url)


def create_db_and_tables() -> None:
    """Create all SQLModel tables in the database if they don't already exist.

    Safe to call multiple times — SQLModel skips existing tables.
    Called from the FastAPI lifespan context at startup.
    """
    SQLModel.metadata.create_all(engine)
    logger.info("Database tables created/verified successfully")


def get_session():
    """FastAPI dependency that yields a database session per request.

    Usage in route handlers:
        from fastapi import Depends
        from app.database import get_session
        from sqlmodel import Session

        @app.get("/something")
        def route(session: Session = Depends(get_session)):
            ...
    """
    with Session(engine) as session:
        yield session
