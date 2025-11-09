#!/usr/bin/env bash
# wifi-mode.sh
# Simple interactive script to list Wi‑Fi interfaces and set monitor/managed mode.
# Requires: sudo, iw, ip, systemctl (for NetworkManager handling)
# Usage: sudo ./wifi-mode.sh

set -euo pipefail

# Command existence check
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Check dependencies
if ! command_exists iw || ! command_exists ip || ! command_exists systemctl; then
  echo "ERROR: This script requires 'iw', 'ip', and 'systemctl'. Install them and try again."
  exit 2
fi

# Run as root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

# Collect wireless interfaces
collect_interfaces() {
  local -a ifs=()
  # Gather interfaces from iw (efficient)
  while IFS= read -r line; do
    [[ -n "$line" ]] && ifs+=("$line")
  done < <(iw dev 2>/dev/null | awk '/Interface/ {print $2}')
  
  echo "${ifs[@]:-}"
}

# Set interface mode (monitor/managed)
set_mode() {
  local ifname="$1"
  local mode="$2"  # monitor or managed
  local action=""

  echo "Setting $ifname -> $mode mode..."
  
  # Stop NetworkManager if running
  if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is active. Stopping temporarily..."
    systemctl stop NetworkManager
  fi

  # Bring interface down before changing mode
  if ip link show dev "$ifname" >/dev/null 2>&1; then
    ip link set dev "$ifname" down || { echo "Failed to bring $ifname down"; return 1; }
  else
    echo "Interface $ifname not found."
    return 2
  fi

  # Set mode using iw
  if iw dev "$ifname" set type "$mode" 2>/dev/null; then
    ip link set dev "$ifname" up || { echo "Failed to bring $ifname up"; return 1; }
    echo "Success: $ifname is now in $mode mode."
    action="success"
  else
    echo "iw failed to set type $mode on $ifname."
    action="failed"
  fi

  # Restart NetworkManager if set to managed mode
  if [[ "$action" == "success" && "$mode" == "managed" ]]; then
    echo "Restarting NetworkManager for $ifname in managed mode..."
    systemctl start NetworkManager
  fi

  return 0
}

# Main loop (interactive mode)
while true; do
  # Collect interfaces
  mapfile -t IFACES < <(collect_interfaces)

  if [[ ${#IFACES[@]} -eq 0 ]]; then
    echo "No wireless interfaces found."
    exit 0
  fi

  # List available interfaces
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
    echo "Please enter a valid number."
    continue
  fi
  if (( sel == 0 )); then
    echo "Goodbye!"
    exit 0
  fi
  if (( sel < 1 || sel > ${#IFACES[@]} )); then
    echo "Invalid selection."
    continue
  fi

  IFNAME="${IFACES[$((sel-1))]}"
  echo
  echo "Selected interface: $IFNAME"
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
      echo "Invalid choice."
      ;;
  esac

  echo
  read -rp "Do you want to change another interface? [Y/n]: " cont
  case "$cont" in
    ''|[Yy]* ) continue ;;
    * ) echo "Exiting."; exit 0 ;;
  esac
done
