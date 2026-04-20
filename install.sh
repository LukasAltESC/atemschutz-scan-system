#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="atemschutz-scan-system"
INSTALL_DIR="/opt/${PROJECT_NAME}"
SERVICE_NAME="${PROJECT_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_USER="${SUDO_USER:-agw}"

# Access-Point-Defaults
# Bei Bedarf vor dem Aufruf ueberschreiben, z. B.:
#   sudo AP_SSID="Atemschutz-Scan-System" AP_PASSPHRASE="GeheimesPasswort" ./install.sh
AP_INTERFACE="${AP_INTERFACE:-wlan0}"
ETH_INTERFACE="${ETH_INTERFACE:-eth0}"
AP_SSID="${AP_SSID:-Atemschutz-Scan-System}"
AP_PASSPHRASE="${AP_PASSPHRASE:-Atemschutz2026}"
AP_OPEN_NETWORK="${AP_OPEN_NETWORK:-0}"
AP_COUNTRY="${AP_COUNTRY:-DE}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_IP_ADDRESS="${AP_IP_ADDRESS:-192.168.50.1}"
AP_PREFIX_LENGTH="${AP_PREFIX_LENGTH:-24}"
AP_NETMASK="${AP_NETMASK:-255.255.255.0}"
AP_DHCP_START="${AP_DHCP_START:-192.168.50.20}"
AP_DHCP_END="${AP_DHCP_END:-192.168.50.150}"
AP_DHCP_LEASE_TIME="${AP_DHCP_LEASE_TIME:-24h}"
AP_CONNECTION_NAME="${AP_CONNECTION_NAME:-atemschutz-access-point}"
AP_LOCAL_HOSTNAME="${AP_LOCAL_HOSTNAME:-atemschutz-scan-system.local}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Bitte mit sudo ausfuehren: sudo ./install.sh"
  exit 1
fi

if ! id "${RUN_USER}" >/dev/null 2>&1; then
  echo "Benutzer ${RUN_USER} existiert nicht. Lege zuerst den User an oder nutze sudo -u."
  exit 1
fi

if [[ "${AP_OPEN_NETWORK}" != "1" ]]; then
  if [[ ${#AP_PASSPHRASE} -lt 8 || ${#AP_PASSPHRASE} -gt 63 ]]; then
    echo "AP_PASSPHRASE muss zwischen 8 und 63 Zeichen lang sein oder AP_OPEN_NETWORK=1 setzen."
    exit 1
  fi
fi

remove_block_from_file() {
  local file_path="$1"
  local start_marker="$2"
  local end_marker="$3"

  if [[ ! -f "${file_path}" ]]; then
    return 0
  fi

  python3 - "$file_path" "$start_marker" "$end_marker" <<'PY'
from pathlib import Path
import sys

file_path = Path(sys.argv[1])
start_marker = sys.argv[2]
end_marker = sys.argv[3]
content = file_path.read_text(encoding='utf-8', errors='ignore')
start = content.find(start_marker)
if start == -1:
    raise SystemExit(0)
end = content.find(end_marker, start)
if end == -1:
    raise SystemExit(0)
end += len(end_marker)
while end < len(content) and content[end] == '\n':
    end += 1
new_content = (content[:start].rstrip('\n') + '\n\n' + content[end:].lstrip('\n')).rstrip() + '\n'
file_path.write_text(new_content, encoding='utf-8')
PY
}

get_interface_ip() {
  local interface_name="$1"
  ip -4 -o addr show dev "${interface_name}" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -n1
}

configure_access_point_with_networkmanager() {
  echo "== Richte WLAN-Access-Point ueber NetworkManager ein =="
  systemctl enable NetworkManager
  systemctl start NetworkManager
  rfkill unblock wlan || true

  nmcli radio wifi on || true
  nmcli device set "${AP_INTERFACE}" managed yes || true

  if nmcli -t -f NAME connection show | grep -Fxq "${AP_CONNECTION_NAME}"; then
    nmcli connection delete "${AP_CONNECTION_NAME}" || true
  fi

  nmcli connection add \
    type wifi \
    ifname "${AP_INTERFACE}" \
    con-name "${AP_CONNECTION_NAME}" \
    autoconnect yes \
    ssid "${AP_SSID}"

  nmcli connection modify "${AP_CONNECTION_NAME}" \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel "${AP_CHANNEL}" \
    802-11-wireless.cloned-mac-address permanent \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    ipv4.method shared \
    ipv4.addresses "${AP_IP_ADDRESS}/${AP_PREFIX_LENGTH}" \
    ipv6.method ignore

  if [[ "${AP_OPEN_NETWORK}" == "1" ]]; then
    nmcli connection modify "${AP_CONNECTION_NAME}" wifi-sec.key-mgmt ""
  else
    nmcli connection modify "${AP_CONNECTION_NAME}" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "${AP_PASSPHRASE}"
  fi

  if ip link show "${ETH_INTERFACE}" >/dev/null 2>&1; then
    local eth_connection_name="${PROJECT_NAME}-ethernet"
    if ! nmcli -t -f NAME,DEVICE connection show | grep -Fq "${eth_connection_name}:${ETH_INTERFACE}"; then
      nmcli connection add \
        type ethernet \
        ifname "${ETH_INTERFACE}" \
        con-name "${eth_connection_name}" \
        ipv4.method auto \
        ipv6.method ignore \
        connection.autoconnect yes || true
    else
      nmcli connection modify "${eth_connection_name}" \
        ipv4.method auto \
        ipv6.method ignore \
        connection.autoconnect yes || true
    fi
    nmcli connection up "${eth_connection_name}" || true
  fi

  nmcli connection up "${AP_CONNECTION_NAME}"
}

configure_access_point_with_classic_stack() {
  echo "== Richte WLAN-Access-Point ueber hostapd/dnsmasq ein =="
  apt install -y hostapd dnsmasq rfkill dhcpcd5
  systemctl unmask hostapd || true
  systemctl enable dhcpcd
  systemctl start dhcpcd
  rfkill unblock wlan || true

  cat > /etc/hostapd/hostapd.conf <<HOSTAPD
country_code=${AP_COUNTRY}
interface=${AP_INTERFACE}
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wmm_enabled=1
ieee80211n=1
HOSTAPD

  if [[ "${AP_OPEN_NETWORK}" == "1" ]]; then
    cat >> /etc/hostapd/hostapd.conf <<'HOSTAPD'
wpa=0
HOSTAPD
  else
    cat >> /etc/hostapd/hostapd.conf <<HOSTAPD
wpa=2
wpa_passphrase=${AP_PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
HOSTAPD
  fi

  if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd 2>/dev/null; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
  fi

  cat > "/etc/dnsmasq.d/${PROJECT_NAME}-ap.conf" <<DNSMASQ
interface=${AP_INTERFACE}
bind-dynamic
domain-needed
bogus-priv
dhcp-authoritative
dhcp-range=${AP_DHCP_START},${AP_DHCP_END},${AP_NETMASK},${AP_DHCP_LEASE_TIME}
dhcp-option=option:router,${AP_IP_ADDRESS}
dhcp-option=option:dns-server,${AP_IP_ADDRESS}
address=/${AP_LOCAL_HOSTNAME}/${AP_IP_ADDRESS}
DNSMASQ

  local start_marker="# >>> ${PROJECT_NAME} access point >>>"
  local end_marker="# <<< ${PROJECT_NAME} access point <<<"
  remove_block_from_file /etc/dhcpcd.conf "${start_marker}" "${end_marker}"
  cat >> /etc/dhcpcd.conf <<DHCP

${start_marker}
interface ${AP_INTERFACE}
static ip_address=${AP_IP_ADDRESS}/${AP_PREFIX_LENGTH}
nohook wpa_supplicant
${end_marker}
DHCP

  systemctl restart dhcpcd
  systemctl enable dnsmasq hostapd
  systemctl restart dnsmasq
  systemctl restart hostapd
}

echo "== Installiere Pakete =="
apt update
apt install -y python3-flask python3-evdev python3-rpi.gpio python3-usb sqlite3 rsync usbutils

echo "== Synchronisiere Projekt nach ${INSTALL_DIR} =="
mkdir -p "${INSTALL_DIR}"

# Laufzeitdateien werden absichtlich nicht aus dem Repository ueberkopiert,
# damit lokale Daten, Einstellungen und Exporte bei Updates erhalten bleiben.
rsync -a --delete \
  --exclude '.git' \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude 'data/atemschutz_scanner.db' \
  --exclude 'data/last_print_payload.json' \
  --exclude 'data/runtime_settings.json' \
  --exclude 'data/exports/' \
  --exclude 'data/function_cards.json' \
  --exclude 'data/detail_checklist.json' \
  --exclude 'data/output_layout.json' \
  --exclude 'data/print_layout.json' \
  "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

mkdir -p "${INSTALL_DIR}/data"
mkdir -p "${INSTALL_DIR}/data/exports"

# Diese Dateien werden nur beim ersten Installieren aus dem Projekt uebernommen.
# Danach bleiben lokale Anpassungen in /opt erhalten.
for file_name in Database.CSV function_cards.json detail_checklist.json output_layout.json print_layout.json; do
  if [[ ! -f "${INSTALL_DIR}/data/${file_name}" && -f "${SCRIPT_DIR}/data/${file_name}" ]]; then
    cp "${SCRIPT_DIR}/data/${file_name}" "${INSTALL_DIR}/data/${file_name}"
  fi
done

chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"

echo "== Setze Berechtigungen fuer Input, GPIO und Druck =="
usermod -a -G input,gpio,lp "${RUN_USER}"

echo "== Installiere Udev-Regel fuer den Thermodrucker =="
cat > /etc/udev/rules.d/99-caysn-thermal-printer.rules <<'RULE'
# Caysn T7-US / kompatibler USB-Thermodrucker
SUBSYSTEM=="usb", ATTR{idVendor}=="4b43", ATTR{idProduct}=="3538", MODE="0660", GROUP="lp", TAG+="uaccess"
RULE
udevadm control --reload-rules
udevadm trigger || true

if command -v nmcli >/dev/null 2>&1 && systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
  configure_access_point_with_networkmanager
else
  configure_access_point_with_classic_stack
fi

echo "== Richte systemd-Service ein =="
sed "s/__RUN_USER__/${RUN_USER}/g" "${INSTALL_DIR}/atemschutz-scan-system.service" > "/etc/systemd/system/${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

AP_WEB_URL="http://${AP_IP_ADDRESS}:5000"
ETH_CURRENT_IP="$(get_interface_ip "${ETH_INTERFACE}")"

echo "== Fertig =="
echo "Access-Point SSID: ${AP_SSID}"
if [[ "${AP_OPEN_NETWORK}" == "1" ]]; then
  echo "Access-Point Sicherheit: offen"
else
  echo "Access-Point Passwort: ${AP_PASSPHRASE}"
fi
echo "Access-Point Webinterface: ${AP_WEB_URL}"
echo "Access-Point SSH: ssh ${RUN_USER}@${AP_IP_ADDRESS}"
if [[ -n "${ETH_CURRENT_IP}" ]]; then
  echo "LAN-Webinterface: http://${ETH_CURRENT_IP}:5000"
  echo "LAN-SSH: ssh ${RUN_USER}@${ETH_CURRENT_IP}"
else
  echo "LAN: DHCP bleibt aktiv. Sobald ${ETH_INTERFACE} verbunden ist, sind SSH und Webinterface ueber die per DHCP vergebene IP erreichbar."
fi
echo "Dokumentation: ${INSTALL_DIR}/docs/"
echo "GPIO-Konfiguration: ${INSTALL_DIR}/config.py"
echo "Bondruck-Layout: ${INSTALL_DIR}/data/print_layout.json"
echo "Scanner-Test: python3 ${INSTALL_DIR}/tools/list_input_devices.py"
echo "GPIO-Test: python3 ${INSTALL_DIR}/tools/test_gpio_io.py"
echo "Drucker-Probe: sudo python3 ${INSTALL_DIR}/tools/test_thermal_printer.py --probe"
echo "Wichtig: Einmal neu einloggen oder rebooten, damit die Gruppenrechte fuer ${RUN_USER} aktiv werden."
