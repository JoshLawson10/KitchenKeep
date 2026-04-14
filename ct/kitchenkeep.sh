#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/refs/heads/main/misc/build.func)
# Copyright (c) 2025 Josh Lawson
# License: MIT
# Source: https://github.com/JoshLawson10/kitchenkeep

APP="KitchenKeep"
var_tags="${var_tags:-recipes;ai;ollama}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-20}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_nesting="${var_nesting:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/kitchenkeep/src ]]; then
    msg_error "No KitchenKeep installation found!"
    exit
  fi
  msg_info "Updating KitchenKeep"
  git -C /opt/kitchenkeep/src pull --ff-only
  /opt/kitchenkeep/venv/bin/pip install --quiet -r /opt/kitchenkeep/src/requirements.txt
  systemctl restart kitchenkeep
  msg_ok "Updated KitchenKeep successfully"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW} Check AI model logs:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}journalctl -u ollama -f${CL}"