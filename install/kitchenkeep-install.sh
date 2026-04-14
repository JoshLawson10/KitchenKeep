#!/usr/bin/env bash
# install/kitchenkeep-install.sh
# Runs INSIDE the newly created LXC container via build.func / create_lxc.sh.
# Sources install.func for msg_info / msg_ok / msg_error helpers.
# tools.func is sourced by build.func and available here via FUNCTIONS_FILE_PATH.

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
# Copyright (c) 2025 Josh Lawson
# License: MIT | https://github.com/JoshLawson10/kitchenkeep

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ────────────────────────────────────────────────────────────
# Read model choice from env var set during advanced install,
# fall back to the sane default.
# ────────────────────────────────────────────────────────────
OLLAMA_MODEL="${OLLAMA_MODEL:-mistral}"
INSTALL_DIR="/opt/kitchenkeep"
SRC_DIR="${INSTALL_DIR}/src"
DATA_DIR="${INSTALL_DIR}/data"
VENV_DIR="${INSTALL_DIR}/venv"
ENV_FILE="${INSTALL_DIR}/.env"
APP_PORT="${APP_PORT:-8000}"
APP_HOST="${APP_HOST:-0.0.0.0}"
APP_USER="kitchenkeep"

# ────────────────────────────────────────────────────────────
# 1 — System dependencies
# ────────────────────────────────────────────────────────────
msg_info "Installing system dependencies"
$STD apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    git \
    ufw \
    zstd
msg_ok "Installed system dependencies"

# ────────────────────────────────────────────────────────────
# 2 — App user & directories
# ────────────────────────────────────────────────────────────
msg_info "Creating app user and directories"
if ! id "$APP_USER" &>/dev/null; then
    useradd --system --shell /usr/sbin/nologin --no-create-home "$APP_USER"
fi
mkdir -p "$DATA_DIR"
chown -R "${APP_USER}:${APP_USER}" "$INSTALL_DIR"
msg_ok "Created user '${APP_USER}' and directories"

# ────────────────────────────────────────────────────────────
# 3 — Clone repo
# ────────────────────────────────────────────────────────────
msg_info "Cloning KitchenKeep repository"
$STD git clone https://github.com/JoshLawson10/kitchenkeep.git "$SRC_DIR"
chown -R "${APP_USER}:${APP_USER}" "$SRC_DIR"
msg_ok "Cloned KitchenKeep to ${SRC_DIR}"

# ────────────────────────────────────────────────────────────
# 4 — Python virtual environment
# ────────────────────────────────────────────────────────────
msg_info "Setting up Python virtualenv"
python3 -m venv "$VENV_DIR"
"${VENV_DIR}/bin/pip" install --upgrade --quiet pip
"${VENV_DIR}/bin/pip" install --quiet -r "${SRC_DIR}/requirements.txt"
chown -R "${APP_USER}:${APP_USER}" "$VENV_DIR"
msg_ok "Python virtualenv ready"

# ────────────────────────────────────────────────────────────
# 5 — Configuration (.env)
# ────────────────────────────────────────────────────────────
msg_info "Writing configuration"
cat >"$ENV_FILE" <<EOF
# KitchenKeep configuration — managed by installer
# Edit and run: systemctl restart kitchenkeep

OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_BASE_URL=http://localhost:11434
APP_PORT=${APP_PORT}
APP_HOST=${APP_HOST}
DATABASE_URL=sqlite:////opt/kitchenkeep/data/recipes.db
DEBUG=false
EOF
chown "${APP_USER}:${APP_USER}" "$ENV_FILE"
chmod 640 "$ENV_FILE"
msg_ok "Configuration written to ${ENV_FILE}"

# ────────────────────────────────────────────────────────────
# 6 — Ollama
# ────────────────────────────────────────────────────────────
msg_info "Installing Ollama"
$STD curl -fsSL https://ollama.com/install.sh | sh
$STD systemctl enable ollama
$STD systemctl start ollama
msg_ok "Ollama installed and started"

msg_info "Waiting for Ollama API to become ready"
for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    msg_error "Ollama did not start within 30 seconds — check: journalctl -u ollama -f"
fi
msg_ok "Ollama API is ready"

# ────────────────────────────────────────────────────────────
# 7 — Pull AI model
# ────────────────────────────────────────────────────────────
msg_info "Pulling AI model '${OLLAMA_MODEL}' (this may take several minutes)"
if ! ollama pull "${OLLAMA_MODEL}"; then
    msg_error "Failed to pull model '${OLLAMA_MODEL}'. Try changing OLLAMA_MODEL in ${ENV_FILE} to phi3:mini and running: ollama pull phi3:mini"
fi
msg_ok "Model '${OLLAMA_MODEL}' ready"

# ────────────────────────────────────────────────────────────
# 8 — systemd service
# ────────────────────────────────────────────────────────────
msg_info "Configuring systemd service"
cp "${SRC_DIR}/systemd/kitchenkeep.service" /etc/systemd/system/kitchenkeep.service
$STD systemctl daemon-reload
$STD systemctl enable kitchenkeep
$STD systemctl start kitchenkeep
msg_ok "kitchenkeep service enabled and started"

# ────────────────────────────────────────────────────────────
# 9 — Firewall
# ────────────────────────────────────────────────────────────
msg_info "Configuring firewall"
$STD ufw allow "${APP_PORT}/tcp" comment "kitchenkeep"
$STD ufw deny  11434/tcp          comment "ollama-internal-only"
$STD ufw --force enable
msg_ok "ufw configured (port ${APP_PORT} open, 11434 blocked)"

# ────────────────────────────────────────────────────────────
# 10 — Motd / version pin
# ────────────────────────────────────────────────────────────
echo "${OLLAMA_MODEL}" >/opt/KitchenKeep_model.txt
motd_ssh
customize