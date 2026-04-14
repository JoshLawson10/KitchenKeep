"""
Web scraper for KitchenKeep.

Fetches a recipe URL and returns the raw HTML for passing to the 
AI extraction model.
"""

import logging

import httpx

logger = logging.getLogger(__name__)

# Realistic browser User-Agent to avoid simple bot-detection blocks
_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
async def fetch_and_clean(url: str) -> str:
    """Fetch a recipe URL and return raw HTML for AI extraction.

    Args:
        url: Fully-qualified URL of the recipe page to scrape.

    Returns:
        Raw HTML text.

    Raises:
        httpx.HTTPStatusError: If the server returns a non-2xx response.
        httpx.RequestError: On network errors or timeouts.
    """
    logger.info("Fetching URL: %s", url)

    async with httpx.AsyncClient(
        timeout=30.0,
        follow_redirects=True,
        headers={"User-Agent": _USER_AGENT},
    ) as client:
        response = await client.get(url)
        response.raise_for_status()

    logger.info("Fetched %s bytes from %s", len(response.content), url)
    return response.text
