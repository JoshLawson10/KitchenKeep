"""
KitchenKeep — FastAPI application entry point.

Defines all API routes and mounts static file serving.
All business logic for scraping and AI extraction lives in scraper.py
and ai_extract.py respectively; route handlers stay thin.

Development setup:
    git clone <repo> && cd kitchenkeep
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    cp .env.example .env
    # Edit .env: DATABASE_URL=sqlite:///./data/recipes.db for local dev
    mkdir -p data
    uvicorn app.main:app --reload --port 8000
"""

import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any, Optional

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from sqlmodel import Session, select

from app.ai_extract import extract_recipe
from app.config import settings
from app.database import create_db_and_tables, get_session
from app.models import Recipe
from app.scraper import fetch_and_clean

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan context (replaces deprecated on_event)
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Handle application startup and shutdown."""
    logger.info("Starting KitchenKeep on %s:%s", settings.app_host, settings.app_port)
    create_db_and_tables()
    yield
    logger.info("KitchenKeep shutting down")


# ---------------------------------------------------------------------------
# FastAPI app instance
# ---------------------------------------------------------------------------

app = FastAPI(
    title="KitchenKeep",
    description="Self-hosted recipe collection powered by Ollama AI",
    version="1.0.0",
    debug=settings.debug,
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Pydantic request / response schemas
# ---------------------------------------------------------------------------


class IngredientItem(BaseModel):
    """Single ingredient with amount, unit, name and optional note."""
    amount: str
    unit: Optional[str] = None
    name: str
    note: Optional[str] = None


class IngredientSection(BaseModel):
    """A named section or grouping of ingredients."""
    section_name: Optional[str] = None
    ingredients: list[IngredientItem]


class RecipeCreate(BaseModel):
    """Request body for creating a new recipe."""
    title: str
    description: Optional[str] = None
    source_url: Optional[str] = None
    image_url: Optional[str] = None
    servings: Optional[int] = None
    prep_time_mins: Optional[int] = None
    cook_time_mins: Optional[int] = None
    ingredient_sections: list[IngredientSection]
    steps: list[str]
    tags: list[str] = []
    notes: Optional[str] = None


class RecipeUpdate(BaseModel):
    """Request body for updating an existing recipe (all fields optional)."""
    title: Optional[str] = None
    description: Optional[str] = None
    source_url: Optional[str] = None
    image_url: Optional[str] = None
    servings: Optional[int] = None
    prep_time_mins: Optional[int] = None
    cook_time_mins: Optional[int] = None
    ingredient_sections: Optional[list[IngredientSection]] = None
    steps: Optional[list[str]] = None
    tags: Optional[list[str]] = None
    notes: Optional[str] = None


class ScrapeRequest(BaseModel):
    """Request body for the URL scrape endpoint."""
    url: str


# ---------------------------------------------------------------------------
# Helper: serialize a Recipe ORM object to a dict
# ---------------------------------------------------------------------------


def _recipe_to_dict(recipe: Recipe, summary: bool = False) -> dict[str, Any]:
    """Serialise a Recipe ORM object to a plain dict for JSON responses.

    Args:
        recipe: The Recipe ORM instance to serialise.
        summary: If True, omit full ingredients/steps/notes (for list views).

    Returns:
        A JSON-serialisable dict.
    """
    base: dict[str, Any] = {
        "id": recipe.id,
        "title": recipe.title,
        "description": recipe.description,
        "image_url": recipe.image_url,
        "servings": recipe.servings,
        "prep_time_mins": recipe.prep_time_mins,
        "cook_time_mins": recipe.cook_time_mins,
        "tags": recipe.tags_list,
        "created_at": recipe.created_at.isoformat(),
        "updated_at": recipe.updated_at.isoformat(),
    }
    if not summary:
        base.update(
            {
                "source_url": recipe.source_url,
                "ingredient_sections": recipe.ingredients_list,
                "steps": recipe.steps_list,
                "notes": recipe.notes,
            }
        )
    return base


# ---------------------------------------------------------------------------
# API Routes — /api prefix
# ---------------------------------------------------------------------------


@app.get("/api/health")
async def health_check() -> dict[str, Any]:
    """Return application health status including Ollama reachability.

    Returns:
        Dict with 'status' always 'ok' and 'ollama' bool indicating if
        the local Ollama service is reachable.
    """
    ollama_ok = False
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{settings.ollama_base_url}/api/tags")
            ollama_ok = resp.status_code == 200
    except Exception:
        pass  # Ollama unreachable — not a fatal error for the app itself

    return {"status": "ok", "ollama": ollama_ok}


@app.get("/api/recipes")
async def list_recipes(
    q: Optional[str] = Query(default=None, description="Full-text search query"),
    tag: Optional[str] = Query(default=None, description="Filter by exact tag"),
    session: Session = Depends(get_session),
) -> list[dict[str, Any]]:
    """Return a list of recipe summaries, optionally filtered.

    Args:
        q: Optional full-text search across title, tags, and ingredients JSON.
        tag: Optional exact-match tag filter.
        session: DB session injected by dependency.

    Returns:
        JSON array of recipe summary objects (id, title, description, tags,
        time fields, image_url, created_at).
    """
    statement = select(Recipe)
    recipes = session.exec(statement).all()

    results: list[Recipe] = []
    for recipe in recipes:
        # Apply full-text search filter
        if q:
            q_lower = q.lower()
            searchable = " ".join(
                [
                    recipe.title,
                    recipe.description or "",
                    recipe.tags,
                    recipe.ingredients,
                ]
            ).lower()
            if q_lower not in searchable:
                continue

        # Apply exact tag filter
        if tag:
            tags_lower = [t.lower() for t in recipe.tags_list]
            if tag.lower() not in tags_lower:
                continue

        results.append(recipe)

    return [_recipe_to_dict(r, summary=True) for r in results]


@app.get("/api/recipes/{recipe_id}")
async def get_recipe(
    recipe_id: int,
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    """Return the full detail of a single recipe.

    Args:
        recipe_id: Primary key of the recipe.
        session: DB session injected by dependency.

    Returns:
        Full recipe dict including ingredients, steps, and notes.

    Raises:
        HTTPException: 404 if the recipe does not exist.
    """
    recipe = session.get(Recipe, recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail={"error": "not_found"})
    return _recipe_to_dict(recipe)


@app.post("/api/recipes", status_code=201)
async def create_recipe(
    body: RecipeCreate,
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    """Create a new recipe from a JSON body.

    Args:
        body: Validated RecipeCreate payload.
        session: DB session injected by dependency.

    Returns:
        The newly created recipe dict including its assigned id.

    Raises:
        HTTPException: 422 if validation fails (handled by FastAPI).
    """
    if not body.ingredient_sections:
        raise HTTPException(
            status_code=422,
            detail={"error": "validation", "field": "ingredient_sections", "message": "Must not be empty"},
        )
    if not body.steps:
        raise HTTPException(
            status_code=422,
            detail={"error": "validation", "field": "steps", "message": "Must not be empty"},
        )

    recipe = Recipe(
        title=body.title,
        description=body.description,
        source_url=body.source_url,
        image_url=body.image_url,
        servings=body.servings,
        prep_time_mins=body.prep_time_mins,
        cook_time_mins=body.cook_time_mins,
        notes=body.notes,
    )
    recipe.ingredients_list = [i.model_dump() for i in body.ingredient_sections]
    recipe.steps_list = body.steps
    recipe.tags_list = [t.strip().lower() for t in body.tags]

    session.add(recipe)
    session.commit()
    session.refresh(recipe)

    logger.info("Created recipe id=%s title=%r", recipe.id, recipe.title)
    return _recipe_to_dict(recipe)


@app.put("/api/recipes/{recipe_id}")
async def update_recipe(
    recipe_id: int,
    body: RecipeUpdate,
    session: Session = Depends(get_session),
) -> dict[str, Any]:
    """Partially update an existing recipe.

    Only provided (non-None) fields are updated.  The updated_at timestamp
    is always refreshed.

    Args:
        recipe_id: Primary key of the recipe to update.
        body: Partial update payload — missing fields are left unchanged.
        session: DB session injected by dependency.

    Returns:
        Updated full recipe dict.

    Raises:
        HTTPException: 404 if recipe not found.
    """
    recipe = session.get(Recipe, recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail={"error": "not_found"})

    update_data = body.model_dump(exclude_unset=True)

    for field, value in update_data.items():
        if field == "ingredient_sections":
            recipe.ingredients_list = [
                i if isinstance(i, dict) else i.model_dump() for i in value
            ]
        elif field == "steps":
            recipe.steps_list = value
        elif field == "tags":
            recipe.tags_list = [t.strip().lower() for t in value]
        else:
            setattr(recipe, field, value)

    recipe.updated_at = datetime.now(timezone.utc)

    session.add(recipe)
    session.commit()
    session.refresh(recipe)

    logger.info("Updated recipe id=%s", recipe_id)
    return _recipe_to_dict(recipe)


@app.delete("/api/recipes/{recipe_id}")
async def delete_recipe(
    recipe_id: int,
    session: Session = Depends(get_session),
) -> dict[str, bool]:
    """Delete a recipe by id.

    Args:
        recipe_id: Primary key of the recipe to delete.
        session: DB session injected by dependency.

    Returns:
        {"ok": true} on success.

    Raises:
        HTTPException: 404 if recipe not found.
    """
    recipe = session.get(Recipe, recipe_id)
    if not recipe:
        raise HTTPException(status_code=404, detail={"error": "not_found"})

    session.delete(recipe)
    session.commit()

    logger.info("Deleted recipe id=%s", recipe_id)
    return {"ok": True}


@app.get("/api/tags")
async def list_tags(
    session: Session = Depends(get_session),
) -> list[str]:
    """Return all unique tags across all recipes, sorted alphabetically.

    Args:
        session: DB session injected by dependency.

    Returns:
        JSON array of tag strings.
    """
    recipes = session.exec(select(Recipe)).all()
    all_tags: set[str] = set()
    for recipe in recipes:
        all_tags.update(recipe.tags_list)
    return sorted(all_tags)


@app.post("/api/scrape")
async def scrape_url(body: ScrapeRequest) -> JSONResponse:
    """Scrape a recipe URL and extract structured data using Ollama.

    Fetches the URL, cleans HTML boilerplate, sends the text to the local
    Ollama model, and returns extracted recipe JSON.  The result is NOT
    saved to the database — the user must confirm via the edit form.

    Args:
        body: Request containing the target URL.

    Returns:
        Extracted recipe JSON on success; error dict on failure.
    """
    logger.info("Scrape request for URL: %s", body.url)

    # Step 1: Fetch and clean HTML
    try:
        cleaned_text = await fetch_and_clean(body.url)
    except httpx.HTTPStatusError as exc:
        logger.warning("HTTP error scraping %s: %s", body.url, exc)
        return JSONResponse(
            status_code=400,
            content={
                "error": "fetch_failed",
                "message": f"Server returned {exc.response.status_code}",
            },
        )
    except Exception as exc:
        logger.error("Fetch error for %s: %s", body.url, exc)
        return JSONResponse(
            status_code=400,
            content={"error": "fetch_failed", "message": str(exc)},
        )

    # Step 2: Check Ollama availability
    ollama_ok = False
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{settings.ollama_base_url}/api/tags")
            ollama_ok = resp.status_code == 200
    except Exception:
        pass

    if not ollama_ok:
        return JSONResponse(
            status_code=503,
            content={"error": "ollama_unavailable"},
        )

    # Step 3: AI extraction
    try:
        extracted = await extract_recipe(cleaned_text)
        # Attach source URL so the form can pre-fill it
        extracted["source_url"] = body.url
        return JSONResponse(content=extracted)
    except ValueError as exc:
        raw = exc.args[0] if exc.args else ""
        logger.error("AI parse failure for %s", body.url)
        return JSONResponse(
            status_code=422,
            content={"error": "parse_failed", "raw": str(raw)},
        )
    except Exception as exc:
        logger.error("Unexpected extraction error: %s", exc, exc_info=True)
        return JSONResponse(
            status_code=500,
            content={"error": "extraction_failed", "message": str(exc)},
        )


# ---------------------------------------------------------------------------
# Static file serving — must be LAST (catch-all)
# ---------------------------------------------------------------------------

app.mount("/", StaticFiles(directory="app/static", html=True), name="static")
