"""
Database schema definitions for KitchenKeep using SQLModel.

Defines the Recipe table with JSON-encoded list fields for ingredients,
steps, and tags. Helper properties decode the JSON on access so callers
always receive Python objects, never raw strings.
"""

import json
import logging
from datetime import datetime, timezone
from typing import Any, Optional

from sqlmodel import Field, SQLModel

logger = logging.getLogger(__name__)


def _utcnow() -> datetime:
    """Return the current UTC datetime (timezone-aware)."""
    return datetime.now(timezone.utc)


class Recipe(SQLModel, table=True):
    """SQLModel ORM model representing a single recipe.

    JSON fields (ingredients, steps, tags) are stored as TEXT in SQLite
    and serialised/deserialised via helper properties.  Always read and
    write those fields through the properties, not the raw _* attributes.
    """

    id: Optional[int] = Field(default=None, primary_key=True)

    # Core identity
    title: str = Field(index=True, description="Recipe title, required")
    description: Optional[str] = Field(default=None)
    source_url: Optional[str] = Field(default=None, description="URL scraped from")
    image_url: Optional[str] = Field(
        default=None, description="External image URL (no local upload in MVP)"
    )

    # Timing and servings
    servings: Optional[int] = Field(default=None)
    prep_time_mins: Optional[int] = Field(default=None)
    cook_time_mins: Optional[int] = Field(default=None)

    # JSON-encoded fields stored as TEXT in SQLite
    # Shape: [{"amount": str, "unit": str|null, "name": str, "note": str|null}]
    ingredients: str = Field(default="[]", description="JSON-encoded ingredient list")
    # Shape: [str, str, ...]
    steps: str = Field(default="[]", description="JSON-encoded ordered step list")
    # Shape: [str, ...]
    tags: str = Field(default="[]", description="JSON-encoded tag list")

    notes: Optional[str] = Field(default=None)

    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)

    # ------------------------------------------------------------------
    # JSON helper properties
    # ------------------------------------------------------------------

    @property
    def ingredients_list(self) -> list[dict[str, Any]]:
        """Return ingredients decoded from JSON as a list of dicts."""
        try:
            data = json.loads(self.ingredients)
            if data and isinstance(data, list) and not ("ingredients" in data[0] or "items" in data[0]):
                return [{"section_name": "", "ingredients": data}]
            return data
        except (json.JSONDecodeError, TypeError):
            logger.warning("Failed to decode ingredients JSON for recipe %s", self.id)
            return []

    @ingredients_list.setter
    def ingredients_list(self, value: list[dict[str, Any]]) -> None:
        """Encode and store ingredient list as JSON."""
        self.ingredients = json.dumps(value, ensure_ascii=False)

    @property
    def steps_list(self) -> list[str]:
        """Return steps decoded from JSON as a list of strings."""
        try:
            return json.loads(self.steps)
        except (json.JSONDecodeError, TypeError):
            logger.warning("Failed to decode steps JSON for recipe %s", self.id)
            return []

    @steps_list.setter
    def steps_list(self, value: list[str]) -> None:
        """Encode and store steps list as JSON."""
        self.steps = json.dumps(value, ensure_ascii=False)

    @property
    def tags_list(self) -> list[str]:
        """Return tags decoded from JSON as a list of strings."""
        try:
            return json.loads(self.tags)
        except (json.JSONDecodeError, TypeError):
            logger.warning("Failed to decode tags JSON for recipe %s", self.id)
            return []

    @tags_list.setter
    def tags_list(self, value: list[str]) -> None:
        """Encode and store tags list as JSON."""
        self.tags = json.dumps(value, ensure_ascii=False)
