#!/bin/sh
# uninstall.sh — KitchenKeep clean removal script
# Prompts before each destructive action.
# Run as root.

set -e

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLD='\033[1m'
RST='\033[0m'

info()  { printf "${GRN}✔ %s${RST}\n" "$*"; }
warn()  { printf "${YEL}⚠ %s${RST}\n" "$*"; }
error() { printf "${RED}✖ %s${RST}\n" "$*" >&2; }

ask() {
    printf "${YEL}%s [y/N] ${RST}" "$1"
    read -r ans
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if [ "$(id -u)" -ne 0 ]; then
    error "Must be run as root."
    exit 1
fi

printf "${BLD}KitchenKeep Uninstaller${RST}\n\n"
printf "This will remove KitchenKeep from this system.\n"
printf "You will be asked before any destructive action.\n\n"

if ! ask "Proceed with uninstall?"; then
    info "Aborted."
    exit 0
fi

# Stop and disable service
if systemctl is-active --quiet kitchenkeep 2>/dev/null; then
    systemctl stop kitchenkeep
    info "Stopped kitchenkeep service"
fi
if systemctl is-enabled --quiet kitchenkeep 2>/dev/null; then
    systemctl disable kitchenkeep
    info "Disabled kitchenkeep service"
fi

SERVICE_FILE="/etc/systemd/system/kitchenkeep.service"
if [ -f "${SERVICE_FILE}" ]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    info "Removed ${SERVICE_FILE}"
fi

# Ollama
if ask "Also remove Ollama and its downloaded models? (Large download to re-obtain)"; then
    if systemctl is-active --quiet ollama 2>/dev/null; then
        systemctl stop ollama
        systemctl disable ollama
        info "Stopped and disabled Ollama service"
    fi
    if command -v ollama >/dev/null 2>&1; then
        # Ollama does not ship an uninstall script; remove binary and data
        rm -f /usr/local/bin/ollama
        rm -rf /usr/share/ollama
        rm -f /etc/systemd/system/ollama.service
        systemctl daemon-reload
        # Remove downloaded models (stored in ~/.ollama for the ollama user)
        if [ -d /root/.ollama ]; then rm -rf /root/.ollama; fi
        if getent passwd ollama >/dev/null 2>&1; then
            OLLAMA_HOME=$(getent passwd ollama | cut -d: -f6)
            if [ -n "${OLLAMA_HOME}" ] && [ -d "${OLLAMA_HOME}/.ollama" ]; then
                rm -rf "${OLLAMA_HOME}/.ollama"
            fi
        fi
        info "Removed Ollama binary and models"
    else
        warn "Ollama binary not found — skipping"
    fi
else
    info "Ollama left in place."
fi

# App data
if ask "Delete /opt/kitchenkeep? (This PERMANENTLY destroys your recipe database!)"; then
    rm -rf /opt/kitchenkeep
    info "Deleted /opt/kitchenkeep"
else
    info "/opt/kitchenkeep left in place. Your recipes are safe."
fi

# App user
if id kitchenkeep >/dev/null 2>&1; then
    if ask "Remove system user 'kitchenkeep'?"; then
        userdel kitchenkeep
        info "Removed user: kitchenkeep"
    fi
fi

# ufw rules
if command -v ufw >/dev/null 2>&1; then
    ufw delete allow kitchenkeep >/dev/null 2>&1 || true
    info "Removed ufw rules"
fi

printf "\n${GRN}Uninstall complete.${RST}\n"
