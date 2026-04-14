#!/bin/sh
# install.sh — KitchenKeep one-shot installer
# POSIX sh compatible (no bash-only syntax)
# Idempotent: safe to run more than once.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<your-username>/kitchenkeep/main/install.sh)
#   bash <(curl -fsSL ...) --yes    # skip interactive prompts

set -e

# -------- Repo URL (change this when forking) --------
REPO_URL="https://github.com/YOUR_USERNAME/kitchenkeep.git"
INSTALL_DIR="/opt/kitchenkeep"
SRC_DIR="${INSTALL_DIR}/src"
DATA_DIR="${INSTALL_DIR}/data"
VENV_DIR="${INSTALL_DIR}/venv"
ENV_FILE="${INSTALL_DIR}/.env"
APP_USER="kitchenkeep"

# -------- ANSI colours --------
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLD='\033[1m'
RST='\033[0m'

info()  { printf "${GRN}✔ %s${RST}\n" "$*"; }
warn()  { printf "${YEL}⚠ %s${RST}\n" "$*"; }
error() { printf "${RED}✖ %s${RST}\n" "$*" >&2; }
step()  { printf "\n${BLD}━━━ %s${RST}\n" "$*"; }

ask_continue() {
    # $1 = question string
    # Returns 0 if user says yes, exits otherwise
    if [ "${AUTO_YES}" = "1" ]; then
        return 0
    fi
    printf "${YEL}%s [y/N] ${RST}" "$1"
    read -r ans
    case "$ans" in
        [Yy]*) return 0 ;;
        *)     error "Aborted."; exit 1 ;;
    esac
}

# Parse --yes flag
AUTO_YES=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=1 ;;
    esac
done

# ================================================================
# STEP 1: PREFLIGHT
# ================================================================
step "PREFLIGHT CHECKS"

# Must be root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (use sudo or log in as root)."
    exit 1
fi

# OS check
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${ID:-unknown}"
else
    OS_NAME="unknown"
fi

case "$OS_NAME" in
    debian|ubuntu)
        info "OS: ${PRETTY_NAME:-$OS_NAME}" ;;
    *)
        warn "Unrecognised OS: ${OS_NAME}. This script is designed for Debian/Ubuntu."
        ask_continue "Continue anyway?" ;;
esac

# RAM check
TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_GB=$(( TOTAL_KB / 1024 / 1024 ))

if [ "${TOTAL_GB}" -lt 4 ]; then
    error "At least 4 GB of RAM is required. Detected: ${TOTAL_GB} GB"
    exit 1
elif [ "${TOTAL_GB}" -lt 6 ]; then
    warn "Only ${TOTAL_GB} GB RAM detected. Recommend using phi3:mini as your model."
    warn "Edit OLLAMA_MODEL=phi3:mini in ${ENV_FILE} after install."
    ask_continue "Continue with limited RAM?"
else
    info "RAM: ${TOTAL_GB} GB — OK"
fi

# Disk check (/opt)
AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
AVAIL_GB=$(( ${AVAIL_KB:-0} / 1024 / 1024 ))

if [ "${AVAIL_GB}" -lt 15 ]; then
    warn "Only ${AVAIL_GB} GB available on /opt. Recommend at least 15 GB for models."
    ask_continue "Continue with limited disk space?"
else
    info "Disk (/opt): ${AVAIL_GB} GB — OK"
fi

# Summary
printf "\n${BLD}The following will be installed:${RST}\n"
printf "  • System packages: python3, python3-pip, python3-venv, curl, git, ufw\n"
printf "  • Ollama (official binary) with model from OLLAMA_MODEL setting\n"
printf "  • KitchenKeep → ${INSTALL_DIR}\n"
printf "  • systemd service: kitchenkeep\n"
printf "  • ufw rule: allow port 8000 (or APP_PORT), block 11434\n\n"

if [ "${AUTO_YES}" != "1" ]; then
    ask_continue "Proceed with installation?"
fi

# ================================================================
# STEP 2: SYSTEM PACKAGES
# ================================================================
step "INSTALLING SYSTEM PACKAGES"
apt-get update -qq
apt-get install -y python3 python3-pip python3-venv curl git ufw
info "System packages installed"

# ================================================================
# STEP 3: APP USER AND DIRECTORIES
# ================================================================
step "CREATING USER AND DIRECTORIES"

if id "$APP_USER" >/dev/null 2>&1; then
    info "User '${APP_USER}' already exists"
else
    useradd --system --shell /usr/sbin/nologin --no-create-home "$APP_USER"
    info "Created system user: ${APP_USER}"
fi

mkdir -p "${DATA_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${INSTALL_DIR}"
info "Directories created: ${INSTALL_DIR}"

# Clone or update repo
if [ -d "${SRC_DIR}/.git" ]; then
    info "Repo already cloned — pulling latest..."
    git -C "${SRC_DIR}" pull --ff-only
else
    git clone "$REPO_URL" "$SRC_DIR"
    info "Cloned repo to ${SRC_DIR}"
fi
chown -R "${APP_USER}:${APP_USER}" "${SRC_DIR}"

# ================================================================
# STEP 4: PYTHON ENVIRONMENT
# ================================================================
step "SETTING UP PYTHON VIRTUALENV"

if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
    info "Virtualenv created at ${VENV_DIR}"
else
    info "Virtualenv already exists"
fi

"${VENV_DIR}/bin/pip" install --upgrade --quiet pip
"${VENV_DIR}/bin/pip" install --quiet -r "${SRC_DIR}/requirements.txt"
info "Python dependencies installed"

chown -R "${APP_USER}:${APP_USER}" "${VENV_DIR}"

# ================================================================
# STEP 5: CONFIGURATION
# ================================================================
step "CONFIGURATION"

if [ ! -f "${ENV_FILE}" ]; then
    cp "${SRC_DIR}/.env.example" "${ENV_FILE}"
    chown "${APP_USER}:${APP_USER}" "${ENV_FILE}"
    chmod 640 "${ENV_FILE}"
    info "Created ${ENV_FILE} from template"
    warn "Review and edit ${ENV_FILE} to customise your setup."
else
    info "${ENV_FILE} already exists — skipping"
fi

# ================================================================
# STEP 6: OLLAMA INSTALL
# ================================================================
step "INSTALLING OLLAMA"

if command -v ollama >/dev/null 2>&1; then
    info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'version unknown')"
else
    info "Downloading Ollama installer..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

systemctl enable ollama >/dev/null 2>&1
systemctl start ollama

# Wait up to 15 seconds for Ollama to be ready
info "Waiting for Ollama to be ready..."
TRIES=0
while [ "$TRIES" -lt 15 ]; do
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        info "Ollama is ready"
        break
    fi
    sleep 1
    TRIES=$(( TRIES + 1 ))
done

if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    warn "Ollama did not become ready in 15 seconds. The model pull may fail."
    warn "Check: journalctl -u ollama -f"
fi

# ================================================================
# STEP 7: MODEL PULL
# ================================================================
step "PULLING AI MODEL"

# Read OLLAMA_MODEL from .env (default: mistral)
OLLAMA_MODEL="mistral"
if [ -f "${ENV_FILE}" ]; then
    _MODEL=$(grep '^OLLAMA_MODEL=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    if [ -n "${_MODEL}" ]; then
        OLLAMA_MODEL="${_MODEL}"
    fi
fi

printf "${YEL}Pulling model '${OLLAMA_MODEL}' — this may take several minutes...${RST}\n"
if ! ollama pull "${OLLAMA_MODEL}"; then
    error "Failed to pull model '${OLLAMA_MODEL}'."
    error "If RAM is limited, try changing OLLAMA_MODEL=phi3:mini in ${ENV_FILE}"
    error "Then run: ollama pull phi3:mini"
    exit 1
fi
info "Model '${OLLAMA_MODEL}' ready"

# ================================================================
# STEP 8: SYSTEMD SERVICE
# ================================================================
step "CONFIGURING SYSTEMD SERVICE"

# Read APP_PORT and APP_HOST from .env
APP_PORT="8000"
APP_HOST="0.0.0.0"
if [ -f "${ENV_FILE}" ]; then
    _PORT=$(grep '^APP_PORT=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    _HOST=$(grep '^APP_HOST=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    if [ -n "${_PORT}" ]; then APP_PORT="${_PORT}"; fi
    if [ -n "${_HOST}" ]; then APP_HOST="${_HOST}"; fi
fi

SERVICE_SRC="${SRC_DIR}/systemd/kitchenkeep.service"
SERVICE_DEST="/etc/systemd/system/kitchenkeep.service"

cp "${SERVICE_SRC}" "${SERVICE_DEST}"
# The service file already uses ${APP_HOST} and ${APP_PORT} via EnvironmentFile,
# so no sed substitution needed — systemd expands them from EnvironmentFile.

systemctl daemon-reload
systemctl enable kitchenkeep
systemctl restart kitchenkeep
info "kitchenkeep service enabled and started"

# ================================================================
# STEP 9: FIREWALL
# ================================================================
step "CONFIGURING FIREWALL (ufw)"

ufw allow "${APP_PORT}/tcp" comment "kitchenkeep" >/dev/null 2>&1
ufw deny 11434/tcp comment "ollama-internal-only" >/dev/null 2>&1

if ufw status | grep -q "Status: inactive"; then
    ufw --force enable >/dev/null 2>&1
    info "ufw enabled"
else
    info "ufw already active — rules applied"
fi

# ================================================================
# STEP 10: DONE
# ================================================================
step "INSTALLATION COMPLETE"

CONTAINER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "your-server-ip")

printf "${GRN}
╔══════════════════════════════════════════════════════╗
║            KitchenKeep is running! 🍳                ║
╠══════════════════════════════════════════════════════╣
║  Open:         http://${CONTAINER_IP}:${APP_PORT}    ║
║  Logs:         journalctl -u kitchenkeep -f           ║
║  Ollama logs:  journalctl -u ollama -f               ║
║  Config:       ${ENV_FILE}                           ║
║  Database:     ${DATA_DIR}/recipes.db                ║
╚══════════════════════════════════════════════════════╝
${RST}"
