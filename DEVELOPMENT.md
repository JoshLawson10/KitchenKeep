# Development Setup

This document covers running KitchenKeep locally for development.

## Prerequisites

- Python 3.11+
- [Ollama](https://ollama.com) installed and running locally
- The model you want to use pulled: `ollama pull mistral`

## Quick start

```sh
git clone <repo-url> kitchenkeep
cd kitchenkeep

# Create and activate virtualenv
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Configure
cp .env.example .env
```

Open `.env` and set:

```
DATABASE_URL=sqlite:///./data/recipes.db
```

(The app auto-detects development mode — no `/opt/kitchenkeep` directory —
and uses `./data/recipes.db` by default even without changing `.env`.)

```sh
# Create local data directory
mkdir -p data

# Start Ollama in another terminal (if not already running)
ollama serve

# Start the dev server with auto-reload
uvicorn app.main:app --reload --port 8000
```

Open `http://localhost:8000` in your browser.

## Project layout

```
kitchenkeep/
├── app/
│   ├── config.py       ← Settings (pydantic-settings, reads .env)
│   ├── models.py       ← SQLModel schema (Recipe table)
│   ├── database.py     ← Engine, get_session() dependency
│   ├── scraper.py      ← URL fetch and HTML cleaning
│   ├── ai_extract.py   ← Ollama prompt + JSON parsing
│   ├── main.py         ← FastAPI routes + static mount
│   └── static/
│       ├── index.html  ← Recipe list + search
│       ├── recipe.html ← Single recipe view
│       ├── edit.html   ← Add / edit form
│       ├── app.js      ← All frontend JS (no framework)
│       └── style.css   ← All CSS (no framework)
├── systemd/
│   └── kitchenkeep.service
├── data/               ← SQLite DB lives here (gitignored)
├── requirements.txt
├── .env.example
├── install.sh
├── uninstall.sh
└── README.md
```

## Environment variables

| Variable         | Default (dev)                    | Description                           |
|-----------------|----------------------------------|---------------------------------------|
| DATABASE_URL    | `sqlite:///./data/recipes.db`    | Auto-set in dev, set explicitly in prod |
| OLLAMA_BASE_URL | `http://localhost:11434`         | Don't change unless Ollama is remote  |
| OLLAMA_MODEL    | `mistral`                        | Any model you've pulled               |
| APP_PORT        | `8000`                           | Uvicorn bind port                     |
| APP_HOST        | `0.0.0.0`                        | Uvicorn bind host                     |
| DEBUG           | `false`                          | SQLAlchemy echo + FastAPI debug mode  |

## Verifying the phases

```sh
# Phase 1 — database
python -c "from app.database import engine; print('DB OK')"

# Phase 2 — API skeleton
curl http://localhost:8000/api/health

# Phase 3 — CRUD
curl -s http://localhost:8000/api/recipes | python3 -m json.tool

# Phase 5 — Scrape (Ollama must be running)
curl -s -X POST http://localhost:8000/api/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://www.allrecipes.com/recipe/20669/award-winning-soft-chocolate-chip-cookies/"}' \
  | python3 -m json.tool
```

## Code style

- Python: type annotations throughout, async/await for all I/O
- Logging: `logging` module (never `print`)
- JS: module pattern under `window.RecipeApp`, no global variables,
  `textContent` not `innerHTML` for user content
