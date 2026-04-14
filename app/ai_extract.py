"""
AI recipe extraction module for KitchenKeep.
"""

import json
import logging
import re
from typing import Any

import ollama
from app.config import settings

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = """\
You are a strict recipe extraction engine.

You MUST return clean, valid JSON only.
No explanations. No markdown. No commentary.

You normalize messy webpage data into structured recipe format.
"""

_USER_PROMPT_TEMPLATE = """\
Extract a recipe from the data below.

IMPORTANT RULES:
- Prefer JSON-LD structured data if present
- Do NOT hallucinate missing values
- Convert times to integers (minutes)
- Split ingredients into: amount, unit, name, note
- Steps must be ordered and clear
- Return null for missing fields

<webpage_data>
{cleaned_text}
</webpage_data>

Return ONLY this JSON:

{{
  "title": "string",
  "description": "string or null",
  "servings": integer or null,
  "prep_time_mins": integer or null,
  "cook_time_mins": integer or null,
  "ingredient_sections": [
    {{
      "section_name": "string or null (e.g. 'For Cupcakes', 'For Icing')",
      "ingredients": [
        {{
          "amount": "string",
          "unit": "string or null",
          "name": "string",
          "note": "string or null"
        }}
      ]
    }}
  ],
  "steps": ["string"],
  "tags": ["string"],
  "notes": "string or null",
  "image_url": "string or null"
}}

If no recipe exists:
{{ "error": "No recipe found" }}
"""


def _strip_markdown_fences(text: str) -> str:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s*```$", "", text)
    return text.strip()


def _extract_json(text: str) -> dict[str, Any]:
    """Robust JSON extraction."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1:
            return json.loads(text[start:end + 1])
        raise


def _validate_extracted(data: dict[str, Any]) -> None:
    if data.get("error"):
        raise ValueError(data["error"])

    required = ["title", "ingredients", "steps"]
    missing = [k for k in required if not data.get(k)]

    if missing:
        raise ValueError(f"Missing required fields: {missing}")


async def extract_recipe(cleaned_text: str, model: str | None = None) -> dict[str, Any]:
    _model = model or settings.ollama_model
    user_prompt = _USER_PROMPT_TEMPLATE.format(cleaned_text=cleaned_text)

    logger.info("Calling Ollama model: %s", _model)

    import asyncio

    def _call():
        client = ollama.Client(host=settings.ollama_base_url)
        res = client.chat(
            model=_model,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            format="json",
        )
        return res.message.content

    raw = await asyncio.to_thread(_call)

    cleaned = _strip_markdown_fences(raw)

    try:
        data = _extract_json(cleaned)
    except Exception:
        logger.error("Failed parsing JSON. Raw:\n%s", raw)
        raise ValueError(raw)

    # unwrap common nesting
    if len(data) == 1 and isinstance(list(data.values())[0], dict):
        data = list(data.values())[0]

    # Model was instructed to use "ingredient_sections", but validation
    # looks for "ingredients" as that's what the UI/schema now uses at the root level.
    if "ingredient_sections" in data and "ingredients" not in data:
        data["ingredients"] = data.pop("ingredient_sections")

    _validate_extracted(data)

    logger.info("Extracted recipe: %s", data.get("title"))
    return data