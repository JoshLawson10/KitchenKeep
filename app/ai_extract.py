"""
AI recipe extraction module for KitchenKeep.

Sends cleaned webpage text to a local Ollama model and parses the
returned JSON into a validated Python dict ready for DB ingestion.
"""

import json
import logging
import re
from typing import Any

import ollama

from app.config import settings

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = """\
You are a recipe data extraction assistant. You will be given the raw HTML of a recipe webpage. Your job is to extract structured recipe information and return it as a single JSON object.

Extract the following fields:

- **title**: The name of the recipe.
- **description**: A short description or introduction of the recipe, if present. Otherwise null.
- **servings**: The number of servings as an integer, if present. Otherwise null.
- **prep_time_mins**: Preparation time in minutes as an integer. Convert hours to minutes if needed (e.g. "1 hr 30 mins" → 90). Null if not present.
- **cook_time_mins**: Cook time in minutes as an integer. Convert hours to minutes if needed. Null if not present.
- **ingredients**: A list of ingredient objects. Each object must have:
  - `amount`: the quantity as a string, preserving fractions (e.g. `"1/2"`, `"2 1/4"`). Empty string `""` if no amount.
  - `unit`: the unit of measurement as a string (e.g. `"cup"`, `"tbsp"`, `"g"`), or null if none.
  - `name`: the ingredient name (e.g. `"all-purpose flour"`, `"unsalted butter"`).
  - `note`: any preparation note or qualifier in parentheses or following the ingredient (e.g. `"finely chopped"`, `"at room temperature"`), or null if none.
  - This list must never be empty if a recipe is present on the page.
- **steps**: A list of plain strings, one instruction step per item. Strip any numbering or bullet formatting.
- **tags**: A list of short, lowercase descriptors inferred from the recipe content and metadata (e.g. `"vegetarian"`, `"italian"`, `"dessert"`, `"gluten-free"`). Use your judgment based on ingredients, cuisine, and dish type.
- **notes**: Any additional tips, variations, or notes sections included in the recipe, as a single string. Null if not present.
- **image_url**: The URL of the primary recipe image if present in the HTML (look for `<img>` tags, `og:image` meta tags, or JSON-LD). Null if not found.

Return ONLY a valid JSON object matching this exact schema. No explanation, no markdown, no code fences — just the raw JSON.

```json
{
  "title": string,
  "description": string | null,
  "servings": integer | null,
  "prep_time_mins": integer | null,
  "cook_time_mins": integer | null,
  "ingredients": [
    { "amount": string, "unit": string | null, "name": string, "note": string | null }
  ],
  "steps": [string],
  "tags": [string],
  "notes": string | null,
  "image_url": string | null
}
```

If the HTML does not appear to contain a recipe, return:
```json
{ "error": "No recipe found" }
```
"""

_USER_PROMPT_TEMPLATE = """\
Webpage HTML:
---
{cleaned_text}
---"""


def _strip_markdown_fences(text: str) -> str:
    """Remove accidental markdown code fences from a string.

    Ollama models sometimes wrap JSON in ```json ... ``` despite being told
    not to.  This strips both ``` and ```json variants.

    Args:
        text: Raw model response string.

    Returns:
        String with markdown fences removed.
    """
    text = text.strip()
    # Remove opening fence (```json or ```)
    text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
    # Remove closing fence
    text = re.sub(r"\s*```$", "", text)
    return text.strip()


def _validate_extracted(data: dict[str, Any]) -> None:
    """Validate that the AI response contains required recipe fields.

    Args:
        data: Parsed dict from AI response.

    Raises:
        ValueError: If required fields are missing or empty.
    """
    if data.get("error"):
        raise ValueError(f"AI reported error: {data['error']}")
        
    missing = []
    if not data.get("title"):
        missing.append("title")
    if not data.get("ingredients"):
        missing.append("ingredients")
    if not data.get("steps"):
        missing.append("steps")
    if missing:
        raise ValueError(f"Required fields missing or empty: {missing}")


async def extract_recipe(cleaned_text: str, model: str | None = None) -> dict[str, Any]:
    """Send cleaned webpage text to Ollama and parse the returned recipe JSON.

    Uses the Ollama Python SDK to call the local Ollama instance
    (defaults to settings.ollama_model if model is not supplied).

    Args:
        cleaned_text: Plain text from the recipe page (max ~8000 chars).
        model: Optional override for the Ollama model name.

    Returns:
        Parsed and validated recipe dict ready for DB ingestion.

    Raises:
        ValueError: If the AI response cannot be parsed or required fields
                    are missing.  The ValueError's first arg is the raw
                    response text for debugging.
        Exception: Propagates Ollama SDK / connection errors to the caller.
    """
    _model = model or settings.ollama_model
    user_prompt = _USER_PROMPT_TEMPLATE.format(cleaned_text=cleaned_text)

    logger.info("Sending extraction request to Ollama model: %s", _model)

    # Ollama python SDK — synchronous call wrapped in async context.
    # The SDK's async support varies by version; we use the sync client
    # here since FastAPI runs it in a thread pool via run_in_executor if needed.
    # Decision: use asyncio.to_thread so the event loop is not blocked.
    import asyncio

    def _call_ollama() -> str:
        client = ollama.Client(host=settings.ollama_base_url)
        response = client.chat(
            model=_model,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            format="json",
        )
        return response.message.content  # type: ignore[union-attr]

    raw_response: str = await asyncio.to_thread(_call_ollama)

    logger.debug("Raw Ollama response (first 500 chars): %s", raw_response[:500])

    cleaned_response = _strip_markdown_fences(raw_response)

    try:
        data: dict[str, Any] = json.loads(cleaned_response)
    except json.JSONDecodeError as exc:
        logger.error("JSON parse failure. Raw response: %s", raw_response)
        raise ValueError(raw_response) from exc

    try:
        _validate_extracted(data)
    except ValueError:
        logger.error("Validation failure on extracted data: %s", data)
        raise

    logger.info("Successfully extracted recipe: %s", data.get("title"))
    return data
