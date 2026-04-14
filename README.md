# KitchenKeep

A self-hosted, AI-powered recipe collection manager. Runs entirely inside a
Proxmox LXC container. No cloud accounts, no subscriptions — your recipes stay
on your server.

## Requirements

| RAM    | Disk   | Recommended model |
|--------|--------|-------------------|
| 4 GB   | 15 GB  | phi3:mini         |
| 6 GB   | 20 GB  | mistral (default) |
| 10 GB  | 30 GB  | llama3            |

> **Note**: The container must have **nesting enabled** for Ollama to function
> correctly. See the Proxmox setup steps below.

---

## Create the LXC in Proxmox

1. Open the Proxmox web UI → **Create CT**
2. **General**: give the container a hostname (e.g. `recipes`)
3. **Template**: choose the **Debian 12** template (download from Proxmox if needed)
4. **Disks**: allocate at least the disk size from the table above
5. **CPU**: 2 cores minimum recommended
6. **Memory**: allocate RAM per the table above
7. **Network**: bridge to your LAN, DHCP or a static IP your choice
8. **Features tab** ← **tick "nesting"** — this is required for Ollama
9. Click **Finish**, then **Start** the container
10. Open the **Console** or SSH in as root

---

## Install

Paste this single command into the container's root shell:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JoshLawson10/kitchenkeep/main/install.sh)
```

To skip all interactive prompts (useful for automation):

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/JoshLawson10/kitchenkeep/main/install.sh) --yes
```

The installer will:
- Install system dependencies
- Clone this repository to `/opt/kitchenkeep/src`
- Set up a Python virtualenv
- Install and start Ollama
- Pull the configured AI model (this can take several minutes)
- Register and start the `kitchenkeep` systemd service
- Open the app port in ufw

When it finishes, open `http://<container-ip>:8000` in your browser.

---

## Changing the AI model

Edit the config file:

```sh
nano /opt/kitchenkeep/.env
```

Change:
```
OLLAMA_MODEL=phi3:mini
```

Then pull the new model and restart the app:

```sh
ollama pull phi3:mini
systemctl restart kitchenkeep
```

Available models:
- `phi3:mini` — 3.8B, fast, works with 4 GB RAM
- `mistral` — 7B, good quality, needs 6 GB RAM  
- `llama3` — 8B, high quality, needs 10 GB RAM

---

## Checking logs

```sh
journalctl -u kitchenkeep -f    # app logs
journalctl -u ollama -f        # AI model logs
```

---

## Backing up your recipes

The entire database is a single SQLite file:

```
/opt/kitchenkeep/data/recipes.db
```

Two recommended approaches:

**Option A — Proxmox backup schedule** (recommended):
Proxmox → Datacenter → Backup → Add schedule for this CT.
The backup includes the whole container including the database.

**Option B — Copy the file manually**:

```sh
cp /opt/kitchenkeep/data/recipes.db /mnt/backup/recipes-$(date +%F).db
```

---

## Updating

```sh
cd /opt/kitchenkeep/src && git pull
systemctl restart kitchenkeep
```

If `requirements.txt` changed, also re-run pip:

```sh
/opt/kitchenkeep/venv/bin/pip install -r /opt/kitchenkeep/src/requirements.txt
```

---

## Uninstall

```sh
bash /opt/kitchenkeep/src/uninstall.sh
```

The script will ask before removing each component (Ollama, models, database).

---

## Architecture

```
Proxmox LXC (Debian 12)
├── Ollama          ← systemd service, listens on localhost:11434 only
│   └── mistral     ← default model, pulled at install time
└── KitchenKeep      ← FastAPI + uvicorn, systemd service, port 8000
    ├── SQLite DB   ← /opt/kitchenkeep/data/recipes.db
    └── Static UI   ← vanilla HTML/CSS/JS served by FastAPI
```

No Docker. No build steps. No external API calls (except when you paste a
recipe URL to import — which only calls that specific URL).
