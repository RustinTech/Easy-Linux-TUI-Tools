#!/usr/bin/env bash
# wifi-mode.sh
# Simple interactive script to list Wi‑Fi interfaces and set monitor/managed mode.
# Requires: sudo, iw, ip, systemctl (for NetworkManager handling)
# Usage: sudo ./wifi-mode.sh

set -euo pipefail

# Helpers
command_exists() { command -v "$1" >/dev/null 2>&1; }

if ! command_exists iw || ! command_exists ip; then
  echo "ERROR: This script requires 'iw' and 'ip'. Install them and try again."
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# Collect wireless interfaces. Combine iw output and ip to be robust.
collect_interfaces() {
  local -a ifs=()
  # from iw
  while IFS= read -r line; do
    [[ -n "$line" ]] && ifs+=("$line")
  done < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}')
  # fallback using ip (match common wifi name patterns)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # avoid duplicates
    skip=false
    for e in "${ifs[@]}"; do [[ "$e" == "$line" ]] && skip=true && break; done
    $skip || ifs+=("$line")
  done < <(ip -o link show | awk -F': ' '{print $2}' | egrep -i 'wlan|wl|wifi' || true)

  echo "${ifs[@]:-}"
}

set_mode() {
  local ifname="$1"
  local mode="$2"  # monitor or managed
  local action=""

  echo "Setting $ifname -> $mode mode..."
  
  # Stop NetworkManager if it's running and managing this device
  if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is active. Stopping NetworkManager temporarily..."
    systemctl stop NetworkManager
  fi

  # Bring interface down before setting mode
  if ip link show dev "$ifname" >/dev/null 2>&1; then
    ip link set dev "$ifname" down || { echo "Failed to bring $ifname down"; return 1; }
  else
    echo "Interface $ifname not found."
    return 2
  fi

  # Set the mode using iw
  if iw dev "$ifname" set type "$mode" 2>/dev/null; then
    ip link set dev "$ifname" up || { echo "Failed to bring $ifname up"; return 1; }
    echo "OK: $ifname is now in $mode mode."
    action="success"
  else
    echo "iw failed to set type $mode on $ifname. Some drivers do not support type change or NetworkManager may interfere."
    # Fallback using iwconfig for older systems (optional)
    if command_exists iwconfig; then
      if [[ $mode == "monitor" ]]; then
        iwconfig "$ifname" mode Monitor 2>/dev/null || true
      else
        iwconfig "$ifname" mode Managed 2>/dev/null || true
      fi
      ip link set dev "$ifname" up || true
      echo "Tried iwconfig fallback (may or may not have worked)."
    fi
    action="fallback"
  fi

  # Restart NetworkManager after mode change if we stopped it
  if [[ "$action" == "success" && "$mode" == "managed" ]]; then
    echo "Restarting NetworkManager after setting $ifname to managed mode..."
    systemctl start NetworkManager
  fi

  return 0
}

# ---- main loop ----
while true; do
  mapfile -t IFACES < <(collect_interfaces)
  if [[ ${#IFACES[@]} -eq 0 ]]; then
    echo "No wireless interfaces found."
    exit 0
  fi

  echo
  echo "Available wireless interfaces:"
  for i in "${!IFACES[@]}"; do
    idx=$((i+1))
    echo "  $idx) ${IFACES[$i]}"
  done
  echo "  0) Quit"
  echo

  read -rp "Select interface number (0 to quit): " sel
  if [[ ! $sel =~ ^[0-9]+$ ]]; then
    echo "Please enter a number."
    continue
  fi
  if (( sel == 0 )); then
    echo "Bye."
    exit 0
  fi
  if (( sel < 1 || sel > ${#IFACES[@]} )); then
    echo "Invalid selection."
    continue
  fi

  IFNAME="${IFACES[$((sel-1))]}"
  echo
  echo "Selected: $IFNAME"
  echo "  1) Set MONITOR mode"
  echo "  2) Set MANAGED mode"
  echo "  3) Back to interface list"
  read -rp "Choose action (1/2/3): " action

  case "$action" in
    1)
      set_mode "$IFNAME" monitor
      ;;
    2)
      set_mode "$IFNAME" managed
      ;;
    3)
      continue
      ;;
    *)
      echo "Invalid action."
      ;;
  esac

  echo
  read -rp "Do you want to do another change? [Y/n]: " cont
  case "$cont" in
    ''|[Yy]* ) continue ;;
    * ) echo "Exiting."; exit 0 ;;
  esac
done

