#!/usr/bin/env bash
# =============================================================================
# KitchenKeep — Proxmox VE LXC Creation Script
#
# Run this from the Proxmox host shell:
#   bash <(curl -fsSL https://raw.githubusercontent.com/JoshLawson10/kitchenkeep/main/install.sh)
#
# This script creates the LXC container itself and then runs the app installer
# inside it.  All Proxmox-side tooling (pct, pvesm, whiptail) is used directly.
# tools.func from community-scripts is sourced for robust curl/apt helpers.
# =============================================================================

set -euo pipefail

# ── Pull in community-scripts tools.func for helpers ─────────────────────────
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/refs/heads/main/misc/tools.func)

# ── ANSI colour / symbol palette ─────────────────────────────────────────────
YW="\e[33m"   # yellow
GN="\e[32m"   # green
RD="\e[31m"   # red
BL="\e[34m"   # blue
CY="\e[36m"   # cyan
BLD="\e[1m"
DIM="\e[2m"
CL="\e[0m"

CROSS="✗"
CHECK="✔"
INFO="ℹ"
HOLD="⏳"

# Whiptail back-title used on every dialog
BT="KitchenKeep — Proxmox VE LXC Installer"

# ── Script defaults ───────────────────────────────────────────────────────────
APP="KitchenKeep"
DEFAULT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
DEFAULT_HOSTNAME="kitchenkeep"
DEFAULT_DISK_SIZE="20"
DEFAULT_CPU="2"
DEFAULT_RAM="6144"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_PORT="8000"
DEFAULT_OS="ubuntu"
DEFAULT_VERSION="24.04"
DEFAULT_OLLAMA_MODEL="mistral"

# Ubuntu versions available in Proxmox templates
UBUNTU_VERSIONS=("20.04" "22.04" "24.04")

# ── Helper: abort cleanly ─────────────────────────────────────────────────────
abort() {
    echo -e "\n${RD}${CROSS} Aborted: ${1:-User cancelled}${CL}\n"
    exit 1
}

# ── Helper: print section header ──────────────────────────────────────────────
header() {
    clear
    echo -e "${BLD}${CY}"
    echo "  ██╗  ██╗██╗████████╗ ██████╗██╗  ██╗███████╗███╗   ██╗"
    echo "  ██║ ██╔╝██║╚══██╔══╝██╔════╝██║  ██║██╔════╝████╗  ██║"
    echo "  █████╔╝ ██║   ██║   ██║     ███████║█████╗  ██╔██╗ ██║"
    echo "  ██╔═██╗ ██║   ██║   ██║     ██╔══██║██╔══╝  ██║╚██╗██║"
    echo "  ██║  ██╗██║   ██║   ╚██████╗██║  ██║███████╗██║ ╚████║"
    echo "  ╚═╝  ╚═╝╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝"
    echo -e "${DIM}                  Self-hosted AI Recipe Manager${CL}"
    echo ""
}

# ── Helper: print summary line ────────────────────────────────────────────────
summary_line() { printf "  ${DIM}%-22s${CL} ${BLD}%s${CL}\n" "$1" "$2"; }

# ── Preflight: must run on a Proxmox node ─────────────────────────────────────
header
if ! command -v pct &>/dev/null; then
    echo -e "${RD}${CROSS} This script must be run on a Proxmox VE host.${CL}"
    exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "${RD}${CROSS} Run as root (or via sudo).${CL}"
    exit 1
fi

# ── Confirm intent ────────────────────────────────────────────────────────────
if ! whiptail \
    --backtitle "$BT" \
    --title "Welcome" \
    --yesno "This will create a new LXC container and install KitchenKeep inside it.\n\nProceed?" \
    10 60; then
    abort "User chose not to proceed."
fi

# ─────────────────────────────────────────────────────────────────────────────
# SETTINGS MENU — Default vs Advanced
# ─────────────────────────────────────────────────────────────────────────────
SETTINGS_CHOICE=$(whiptail \
    --backtitle "$BT" \
    --title "Installation Mode" \
    --menu "Choose how to configure the new container:" \
    12 60 3 \
    "1" "Default Settings (quick start)" \
    "2" "Advanced Settings (full control)" \
    3>&1 1>&2 2>&3) || abort

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT PATH — use all defaults, skip straight to confirmation
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SETTINGS_CHOICE" == "1" ]]; then
    CT_ID="$DEFAULT_CTID"
    CT_HOSTNAME="$DEFAULT_HOSTNAME"
    CT_DISK_SIZE="$DEFAULT_DISK_SIZE"
    CT_CPU="$DEFAULT_CPU"
    CT_RAM="$DEFAULT_RAM"
    CT_BRIDGE="$DEFAULT_BRIDGE"
    CT_OS="$DEFAULT_OS"
    CT_VERSION="$DEFAULT_VERSION"
    CT_UNPRIVILEGED=1
    CT_PASSWORD=""          # empty = auto-login
    CT_IPV6="no"
    CT_MTU=""
    CT_DNS_DOMAIN=""
    CT_DNS_SERVER=""
    CT_MAC=""
    CT_VLAN=""
    CT_SSH="no"
    VERBOSE="no"
    OLLAMA_MODEL="$DEFAULT_OLLAMA_MODEL"

    # Pick storage pool
    STORAGE_LIST=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1, $2}')
    STORAGE_COUNT=$(echo "$STORAGE_LIST" | wc -l)

    if [[ "$STORAGE_COUNT" -eq 1 ]]; then
        CT_STORAGE=$(echo "$STORAGE_LIST" | awk '{print $1}')
    else
        STORAGE_MENU=()
        while read -r id type; do
            STORAGE_MENU+=("$id" "$type")
        done <<< "$STORAGE_LIST"
        CT_STORAGE=$(whiptail \
            --backtitle "$BT" \
            --title "Storage Pool" \
            --menu "Select the storage pool for the container disk:" \
            15 60 6 \
            "${STORAGE_MENU[@]}" \
            3>&1 1>&2 2>&3) || abort
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# ADVANCED PATH
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$SETTINGS_CHOICE" == "2" ]]; then

    # ── OS version ────────────────────────────────────────────────────────────
    CT_OS="ubuntu"
    VERSION_MENU=()
    for v in "${UBUNTU_VERSIONS[@]}"; do
        VERSION_MENU+=("$v" "Ubuntu $v")
    done
    CT_VERSION=$(whiptail \
        --backtitle "$BT" \
        --title "Ubuntu Version" \
        --menu "Select the Ubuntu version for the container:" \
        12 50 4 \
        "${VERSION_MENU[@]}" \
        3>&1 1>&2 2>&3) || abort

    # ── Container type ────────────────────────────────────────────────────────
    PRIV_CHOICE=$(whiptail \
        --backtitle "$BT" \
        --title "Container Type" \
        --menu "Choose container privilege level:\n(Unprivileged is recommended)" \
        12 60 2 \
        "1" "Unprivileged (recommended)" \
        "2" "Privileged" \
        3>&1 1>&2 2>&3) || abort
    [[ "$PRIV_CHOICE" == "1" ]] && CT_UNPRIVILEGED=1 || CT_UNPRIVILEGED=0

    # ── Root password ─────────────────────────────────────────────────────────
    CT_PASSWORD=$(whiptail \
        --backtitle "$BT" \
        --title "Root Password" \
        --passwordbox "Set root password for the container.\nLeave blank to enable automatic login:" \
        10 60 \
        3>&1 1>&2 2>&3) || abort

    # ── Container ID ─────────────────────────────────────────────────────────
    while true; do
        CT_ID=$(whiptail \
            --backtitle "$BT" \
            --title "Container ID" \
            --inputbox "Set the container ID (CTID):" \
            8 50 "$DEFAULT_CTID" \
            3>&1 1>&2 2>&3) || abort
        if [[ "$CT_ID" =~ ^[0-9]+$ ]] && [[ "$CT_ID" -ge 100 ]]; then
            if pct status "$CT_ID" &>/dev/null; then
                whiptail --backtitle "$BT" --title "Error" --msgbox "Container ID ${CT_ID} already exists. Choose another." 8 50
            else
                break
            fi
        else
            whiptail --backtitle "$BT" --title "Error" --msgbox "Container ID must be a number ≥ 100." 8 50
        fi
    done

    # ── Hostname ─────────────────────────────────────────────────────────────
    while true; do
        CT_HOSTNAME=$(whiptail \
            --backtitle "$BT" \
            --title "Hostname" \
            --inputbox "Set the container hostname:" \
            8 50 "$DEFAULT_HOSTNAME" \
            3>&1 1>&2 2>&3) || abort
        if [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]; then
            break
        else
            whiptail --backtitle "$BT" --title "Error" --msgbox "Invalid hostname. Use letters, numbers and hyphens only." 8 60
        fi
    done

    # ── Disk size ─────────────────────────────────────────────────────────────
    while true; do
        CT_DISK_SIZE=$(whiptail \
            --backtitle "$BT" \
            --title "Disk Size" \
            --inputbox "Disk size in GB.\n(Minimum 15 GB recommended for model storage):" \
            9 55 "$DEFAULT_DISK_SIZE" \
            3>&1 1>&2 2>&3) || abort
        if [[ "$CT_DISK_SIZE" =~ ^[0-9]+$ ]] && [[ "$CT_DISK_SIZE" -ge 10 ]]; then
            break
        else
            whiptail --backtitle "$BT" --title "Error" --msgbox "Disk size must be a number ≥ 10 GB." 8 50
        fi
    done

    # ── CPU cores ─────────────────────────────────────────────────────────────
    while true; do
        CT_CPU=$(whiptail \
            --backtitle "$BT" \
            --title "CPU Cores" \
            --inputbox "Number of CPU cores to allocate:" \
            8 50 "$DEFAULT_CPU" \
            3>&1 1>&2 2>&3) || abort
        if [[ "$CT_CPU" =~ ^[0-9]+$ ]] && [[ "$CT_CPU" -ge 1 ]]; then
            break
        else
            whiptail --backtitle "$BT" --title "Error" --msgbox "CPU cores must be a number ≥ 1." 8 50
        fi
    done

    # ── RAM ───────────────────────────────────────────────────────────────────
    while true; do
        CT_RAM=$(whiptail \
            --backtitle "$BT" \
            --title "RAM" \
            --inputbox "RAM in MiB.\n  phi3:mini → 4096 MiB\n  mistral   → 6144 MiB (default)\n  llama3    → 10240 MiB:" \
            11 60 "$DEFAULT_RAM" \
            3>&1 1>&2 2>&3) || abort
        if [[ "$CT_RAM" =~ ^[0-9]+$ ]] && [[ "$CT_RAM" -ge 2048 ]]; then
            break
        else
            whiptail --backtitle "$BT" --title "Error" --msgbox "RAM must be a number ≥ 2048 MiB." 8 50
        fi
    done

    # ── Bridge ────────────────────────────────────────────────────────────────
    CT_BRIDGE=$(whiptail \
        --backtitle "$BT" \
        --title "Network Bridge" \
        --inputbox "Network bridge to attach the container to:" \
        8 50 "$DEFAULT_BRIDGE" \
        3>&1 1>&2 2>&3) || abort

    # ── Disable IPv6? ─────────────────────────────────────────────────────────
    if whiptail \
        --backtitle "$BT" \
        --title "IPv6" \
        --yesno "Disable IPv6 for this container?" \
        8 50; then
        CT_IPV6="yes"
    else
        CT_IPV6="no"
    fi

    # ── MTU ───────────────────────────────────────────────────────────────────
    CT_MTU=$(whiptail \
        --backtitle "$BT" \
        --title "Interface MTU Size" \
        --inputbox "Set interface MTU size.\nLeave blank to use the bridge default:" \
        9 55 "" \
        3>&1 1>&2 2>&3) || abort

    # ── DNS Search Domain ─────────────────────────────────────────────────────
    CT_DNS_DOMAIN=$(whiptail \
        --backtitle "$BT" \
        --title "DNS Search Domain" \
        --inputbox "Set a DNS search domain.\nLeave blank to inherit from the Proxmox host:" \
        9 60 "" \
        3>&1 1>&2 2>&3) || abort

    # ── DNS Server ────────────────────────────────────────────────────────────
    CT_DNS_SERVER=$(whiptail \
        --backtitle "$BT" \
        --title "DNS Server IP" \
        --inputbox "Set a DNS server IP address.\nLeave blank to inherit from the Proxmox host:" \
        9 60 "" \
        3>&1 1>&2 2>&3) || abort

    # ── MAC Address ───────────────────────────────────────────────────────────
    CT_MAC=$(whiptail \
        --backtitle "$BT" \
        --title "MAC Address" \
        --inputbox "Set a custom MAC address (XX:XX:XX:XX:XX:XX).\nLeave blank for Proxmox default:" \
        9 60 "" \
        3>&1 1>&2 2>&3) || abort
    # Validate if provided
    if [[ -n "$CT_MAC" ]] && [[ ! "$CT_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        whiptail --backtitle "$BT" --title "Warning" \
            --msgbox "MAC address format looks invalid — proceeding anyway." 8 50
    fi

    # ── VLAN ──────────────────────────────────────────────────────────────────
    CT_VLAN=$(whiptail \
        --backtitle "$BT" \
        --title "VLAN Tag" \
        --inputbox "Set a VLAN tag (1–4094).\nLeave blank for no VLAN:" \
        9 55 "" \
        3>&1 1>&2 2>&3) || abort

    # ── Root SSH access ───────────────────────────────────────────────────────
    if whiptail \
        --backtitle "$BT" \
        --title "SSH Access" \
        --yesno "Enable root SSH access to this container?" \
        8 55; then
        CT_SSH="yes"
    else
        CT_SSH="no"
    fi

    # ── Verbose mode ─────────────────────────────────────────────────────────
    if whiptail \
        --backtitle "$BT" \
        --title "Verbose Install" \
        --yesno "Enable verbose install mode?\n(Shows full output inside the container)" \
        9 55; then
        VERBOSE="yes"
    else
        VERBOSE="no"
    fi

    # ── Ollama model ──────────────────────────────────────────────────────────
    OLLAMA_MODEL=$(whiptail \
        --backtitle "$BT" \
        --title "Ollama AI Model" \
        --menu "Choose the AI model for recipe extraction:\n(Higher quality needs more RAM)" \
        14 65 3 \
        "phi3:mini" "3.8B — Fast, works with 4 GB RAM" \
        "mistral"   "7B   — Good quality, needs 6 GB RAM (default)" \
        "llama3"    "8B   — Best quality, needs 10 GB RAM" \
        3>&1 1>&2 2>&3) || abort

    # ── Storage pool ─────────────────────────────────────────────────────────
    STORAGE_LIST=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1, $2}')
    STORAGE_COUNT=$(echo "$STORAGE_LIST" | wc -l)
    if [[ "$STORAGE_COUNT" -eq 1 ]]; then
        CT_STORAGE=$(echo "$STORAGE_LIST" | awk '{print $1}')
    else
        STORAGE_MENU=()
        while read -r id type; do
            STORAGE_MENU+=("$id" "$type")
        done <<< "$STORAGE_LIST"
        CT_STORAGE=$(whiptail \
            --backtitle "$BT" \
            --title "Storage Pool" \
            --menu "Select the storage pool for the container disk:" \
            15 60 6 \
            "${STORAGE_MENU[@]}" \
            3>&1 1>&2 2>&3) || abort
    fi

fi   # end advanced settings

# ─────────────────────────────────────────────────────────────────────────────
# CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────
header

PRIV_LABEL="Unprivileged"
[[ "${CT_UNPRIVILEGED:-1}" == "0" ]] && PRIV_LABEL="Privileged"

PASS_LABEL="(automatic login)"
[[ -n "${CT_PASSWORD:-}" ]] && PASS_LABEL="(password set)"

SSH_LABEL="${CT_SSH:-no}"
IPV6_LABEL="enabled"
[[ "${CT_IPV6:-no}" == "yes" ]] && IPV6_LABEL="disabled"

MTU_LABEL="${CT_MTU:-bridge default}"
DNS_DOMAIN_LABEL="${CT_DNS_DOMAIN:-host default}"
DNS_SERVER_LABEL="${CT_DNS_SERVER:-host default}"
MAC_LABEL="${CT_MAC:-Proxmox default}"
VLAN_LABEL="${CT_VLAN:-none}"

echo -e "${BLD}  Summary — Review before creating:${CL}"
echo ""
summary_line "App"                "$APP"
summary_line "Container ID"       "$CT_ID"
summary_line "Hostname"           "$CT_HOSTNAME"
summary_line "OS"                 "Ubuntu ${CT_VERSION}"
summary_line "Type"               "$PRIV_LABEL"
summary_line "Root password"      "$PASS_LABEL"
summary_line "Disk"               "${CT_DISK_SIZE} GB  on  ${CT_STORAGE}"
summary_line "CPU cores"          "$CT_CPU"
summary_line "RAM"                "${CT_RAM} MiB"
summary_line "Bridge"             "$CT_BRIDGE"
summary_line "IPv6"               "$IPV6_LABEL"
summary_line "MTU"                "$MTU_LABEL"
summary_line "DNS search domain"  "$DNS_DOMAIN_LABEL"
summary_line "DNS server"         "$DNS_SERVER_LABEL"
summary_line "MAC address"        "$MAC_LABEL"
summary_line "VLAN tag"           "$VLAN_LABEL"
summary_line "Root SSH"           "$SSH_LABEL"
summary_line "Verbose install"    "${VERBOSE:-no}"
summary_line "Ollama model"       "$OLLAMA_MODEL"
echo ""

if ! whiptail \
    --backtitle "$BT" \
    --title "Confirm Installation" \
    --yesno "The LXC container will now be created with the settings above.\n\nThis cannot be undone — proceed?" \
    10 65; then
    abort "User cancelled at confirmation."
fi

# ─────────────────────────────────────────────────────────────────────────────
# TEMPLATE — locate or download Ubuntu cloud image
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${INFO} Looking up Ubuntu ${CT_VERSION} template on storage '${CT_STORAGE}'..."

TEMPLATE_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
if [[ -z "$TEMPLATE_STORAGE" ]]; then
    echo -e "${RD}${CROSS} No storage found that supports container templates. Add one in the Proxmox UI.${CL}"
    exit 1
fi

# Find existing template matching the version
TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
    | grep -i "ubuntu-${CT_VERSION}" \
    | sort -V \
    | tail -1 \
    | awk '{print $1}')

if [[ -z "$TEMPLATE" ]]; then
    echo -e "${INFO} Template not found locally — downloading from Proxmox repository..."
    # Update template list then download
    pveam update 2>/dev/null || true
    AVAILABLE=$(pveam available --section system 2>/dev/null \
        | grep -i "ubuntu-${CT_VERSION}" \
        | sort -V \
        | tail -1 \
        | awk '{print $2}')
    if [[ -z "$AVAILABLE" ]]; then
        echo -e "${RD}${CROSS} Ubuntu ${CT_VERSION} template not available from Proxmox. Check your network.${CL}"
        exit 1
    fi
    pveam download "$TEMPLATE_STORAGE" "$AVAILABLE"
    TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${AVAILABLE}"
    echo -e "${GN}${CHECK} Template downloaded: ${TEMPLATE}${CL}"
else
    echo -e "${GN}${CHECK} Found template: ${TEMPLATE}${CL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# BUILD pct CREATE COMMAND
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${INFO} Creating LXC container ${CT_ID} (${CT_HOSTNAME})..."

PCT_ARGS=(
    "$CT_ID"
    "$TEMPLATE"
    --hostname "$CT_HOSTNAME"
    --cores    "$CT_CPU"
    --memory   "$CT_RAM"
    --swap     "512"
    --rootfs   "${CT_STORAGE}:${CT_DISK_SIZE}"
    --net0     "name=eth0,bridge=${CT_BRIDGE},ip=dhcp${CT_IPV6:+,ip6=manual}"
    --features "nesting=1"
    --unprivileged "${CT_UNPRIVILEGED:-1}"
    --start    "1"
)

# Optional: root password or auto-login
if [[ -n "${CT_PASSWORD:-}" ]]; then
    PCT_ARGS+=(--password "$CT_PASSWORD")
fi

# Optional: SSH public key (root SSH)
if [[ "${CT_SSH:-no}" == "yes" ]]; then
    PCT_ARGS+=(--ssh-public-keys "$(cat ~/.ssh/authorized_keys 2>/dev/null || true)")
fi

# Optional: MTU
if [[ -n "${CT_MTU:-}" ]]; then
    # Append to net0 arg — rebuild it
    NET0="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
    [[ "${CT_IPV6:-no}" == "yes" ]] && NET0+=",ip6=manual"
    [[ -n "$CT_MTU" ]] && NET0+=",mtu=${CT_MTU}"
    [[ -n "${CT_MAC:-}" ]] && NET0+=",hwaddr=${CT_MAC}"
    [[ -n "${CT_VLAN:-}" ]] && NET0+=",tag=${CT_VLAN}"
    # Replace the --net0 entry
    PCT_ARGS=(
        "$CT_ID"
        "$TEMPLATE"
        --hostname "$CT_HOSTNAME"
        --cores    "$CT_CPU"
        --memory   "$CT_RAM"
        --swap     "512"
        --rootfs   "${CT_STORAGE}:${CT_DISK_SIZE}"
        --net0     "$NET0"
        --features "nesting=1"
        --unprivileged "${CT_UNPRIVILEGED:-1}"
        --start    "1"
    )
    [[ -n "${CT_PASSWORD:-}" ]] && PCT_ARGS+=(--password "$CT_PASSWORD")
    [[ "${CT_SSH:-no}" == "yes" ]] && PCT_ARGS+=(--ssh-public-keys "$(cat ~/.ssh/authorized_keys 2>/dev/null || true)")
else
    # Still apply MAC and VLAN even without MTU
    if [[ -n "${CT_MAC:-}" ]] || [[ -n "${CT_VLAN:-}" ]]; then
        NET0="name=eth0,bridge=${CT_BRIDGE},ip=dhcp"
        [[ "${CT_IPV6:-no}" == "yes" ]] && NET0+=",ip6=manual"
        [[ -n "${CT_MAC:-}" ]] && NET0+=",hwaddr=${CT_MAC}"
        [[ -n "${CT_VLAN:-}" ]] && NET0+=",tag=${CT_VLAN}"
        # Rebuild args replacing net0
        PCT_ARGS=(
            "$CT_ID"
            "$TEMPLATE"
            --hostname "$CT_HOSTNAME"
            --cores    "$CT_CPU"
            --memory   "$CT_RAM"
            --swap     "512"
            --rootfs   "${CT_STORAGE}:${CT_DISK_SIZE}"
            --net0     "$NET0"
            --features "nesting=1"
            --unprivileged "${CT_UNPRIVILEGED:-1}"
            --start    "1"
        )
        [[ -n "${CT_PASSWORD:-}" ]] && PCT_ARGS+=(--password "$CT_PASSWORD")
        [[ "${CT_SSH:-no}" == "yes" ]] && PCT_ARGS+=(--ssh-public-keys "$(cat ~/.ssh/authorized_keys 2>/dev/null || true)")
    fi
fi

# DNS options
[[ -n "${CT_DNS_DOMAIN:-}" ]] && PCT_ARGS+=(--searchdomain "$CT_DNS_DOMAIN")
[[ -n "${CT_DNS_SERVER:-}" ]] && PCT_ARGS+=(--nameserver "$CT_DNS_SERVER")

pct create "${PCT_ARGS[@]}"
echo -e "${GN}${CHECK} Container ${CT_ID} created.${CL}"

# ─────────────────────────────────────────────────────────────────────────────
# SSH config: allow root login if requested
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${CT_SSH:-no}" == "yes" ]]; then
    echo -e "${INFO} Enabling root SSH login inside container..."
    pct exec "$CT_ID" -- bash -c \
        "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && systemctl restart ssh 2>/dev/null || true"
    echo -e "${GN}${CHECK} Root SSH access enabled.${CL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Disable IPv6 inside the container if requested
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${CT_IPV6:-no}" == "yes" ]]; then
    echo -e "${INFO} Disabling IPv6 inside container..."
    pct exec "$CT_ID" -- bash -c "
        echo 'net.ipv6.conf.all.disable_ipv6 = 1'     >> /etc/sysctl.d/99-disable-ipv6.conf
        echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> /etc/sysctl.d/99-disable-ipv6.conf
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf  >/dev/null 2>&1 || true
    "
    echo -e "${GN}${CHECK} IPv6 disabled.${CL}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# RUN KITCHENKEEP INSTALLER INSIDE THE CONTAINER
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${INFO} ${HOLD} Running KitchenKeep installer inside container ${CT_ID}..."
echo -e "${DIM}    This may take 5–15 minutes while the AI model downloads.${CL}"
echo ""

# Export relevant settings as env vars for the install script
INSTALL_ENV="OLLAMA_MODEL=${OLLAMA_MODEL} APP_PORT=${DEFAULT_PORT}"
[[ "${VERBOSE:-no}" == "yes" ]] && VERBOSE_FLAG="" || VERBOSE_FLAG=" >/dev/null"

pct exec "$CT_ID" -- bash -c "
    ${INSTALL_ENV} bash <(curl -fsSL https://raw.githubusercontent.com/JoshLawson10/kitchenkeep/main/install/kitchenkeep-install.sh)
"

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
CT_IP=$(pct exec "$CT_ID" -- bash -c "hostname -I 2>/dev/null | awk '{print \$1}'" || echo "your-container-ip")

header
echo -e "${GN}${BLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         KitchenKeep is up and running! 🍳            ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf  "  ║  Container:  LXC %-33s║\n" "${CT_ID} (${CT_HOSTNAME})"
printf  "  ║  URL:        http://%-32s║\n" "${CT_IP}:${DEFAULT_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  App logs:   journalctl -u kitchenkeep -f            ║"
echo "  ║  AI logs:    journalctl -u ollama -f                 ║"
printf  "  ║  Config:     %-39s║\n" "/opt/kitchenkeep/.env"
printf  "  ║  Database:   %-39s║\n" "/opt/kitchenkeep/data/recipes.db"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  To update:  run this script again from the host     ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${CL}"