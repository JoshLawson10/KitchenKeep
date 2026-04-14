"""
Web scraper for KitchenKeep.

Fetches a recipe URL, strips boilerplate HTML (scripts, styles, nav, ads),
and returns a compact text representation suitable for passing to a local
LLM with a limited context window.
"""

import json
import logging
import re
from typing import Any

import httpx
from bs4 import BeautifulSoup

logger = logging.getLogger(__name__)

_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

_STRIP_TAGS = {
    "script", "style", "noscript", "iframe", "svg", "canvas",
    "header", "footer", "nav", "aside",
    "form", "button", "input", "select", "textarea",
    "figure",
    "advertisement",
}

_NOISE_PATTERNS = re.compile(
    r"(comment|sidebar|related|social|share|ad[-_]|promo|newsletter"
    r"|cookie|popup|modal|overlay|banner|breadcrumb|pagination"
    r"|author-bio|widget|footer|header|nav|menu)",
    re.IGNORECASE,
)

_MAX_CHARS = 12_000


def _looks_noisy(tag) -> bool:
    if not hasattr(tag, "get"):
        return False
    for attr in ("class", "id"):
        val = tag.get(attr) or ""
        if isinstance(val, list):
            val = " ".join(val)
        if val and _NOISE_PATTERNS.search(val):
            return True
    return False


def _is_recipe_json(data: Any) -> bool:
    """Detect if JSON-LD block likely contains recipe data."""
    if isinstance(data, dict):
        if data.get("@type") in ("Recipe", ["Recipe"]):
            return True
        if "recipeIngredient" in data or "recipeInstructions" in data:
            return True
    if isinstance(data, list):
        return any(_is_recipe_json(item) for item in data)
    return False


def _extract_json_ld(soup: BeautifulSoup) -> str:
    """Extract only recipe-relevant JSON-LD."""
    blocks = []

    for tag in soup.find_all("script", type="application/ld+json"):
        raw = tag.get_text(strip=True)

        try:
            parsed = json.loads(raw)
        except Exception:
            continue

        if _is_recipe_json(parsed):
            blocks.append(json.dumps(parsed))

    return "\n".join(blocks)


def _clean_html(html: str) -> str:
    soup = BeautifulSoup(html, "lxml")

    json_ld = _extract_json_ld(soup)

    for tag in soup.find_all(_STRIP_TAGS):
        tag.decompose()

    noisy_tags = [
        tag for tag in soup.find_all(True)
        if tag.parent is not None and _looks_noisy(tag)
    ]
    for tag in noisy_tags:
        tag.decompose()

    content_node = (
        soup.find("main")
        or soup.find("article")
        or soup.find(True, id=re.compile(r"recipe", re.I))
        or soup.find(True, class_=re.compile(r"recipe", re.I))
        or soup.body
        or soup
    )

    raw_text = content_node.get_text(separator="\n", strip=True)

    lines = [l.strip() for l in raw_text.splitlines() if l.strip()]

    deduplicated: list[str] = []
    prev = None
    for line in lines:
        if line != prev:
            deduplicated.append(line)
            prev = line

    page_text = "\n".join(deduplicated)

    if json_ld:
        combined = (
            f"=== STRUCTURED DATA (JSON-LD) ===\n{json_ld}"
            f"\n\n=== PAGE TEXT ===\n{page_text}"
        )
    else:
        combined = page_text

    if len(combined) > _MAX_CHARS:
        combined = combined[:_MAX_CHARS] + "\n...[truncated]"

    return combined


async def fetch_and_clean(url: str) -> str:
    logger.info("Fetching URL: %s", url)

    async with httpx.AsyncClient(
        timeout=30.0,
        follow_redirects=True,
        headers={"User-Agent": _USER_AGENT},
    ) as client:
        response = await client.get(url)
        response.raise_for_status()

    cleaned = _clean_html(response.text)

    logger.info("Cleaned text length: %s chars", len(cleaned))
    return cleaned