#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/wireguard/render-profile-configs.sh"
TRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf.example"
UNTRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf.example"
TRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf"
UNTRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf"
TRUSTED_PRIVATE_KEY_FILE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.privatekey"
TRUSTED_PUBLIC_KEY_FILE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.publickey"
UNTRUSTED_PRIVATE_KEY_FILE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.privatekey"
UNTRUSTED_PUBLIC_KEY_FILE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.publickey"
CONSOLEPI_RUNTIME_DIR="${SCRIPT_DIR}/consolepi/runtime"
CONSOLEPI_CLOUD_CACHE_FILE="${CONSOLEPI_RUNTIME_DIR}/cloud.json"
CONSOLEPI_RUNTIME_CONFIG_FILE="${CONSOLEPI_RUNTIME_DIR}/ConsolePi.yaml"
WITH_CONSOLEPI="true"
REFRESH_CONFIGS="false"
ROTATE_KEYS="false"
PRINT_KEYS="false"
PRINT_HOSTS="false"
PRINT_HOSTS_ONLY="false"
HOSTS_MAIN_MENU_PREFIXES="${HOSTS_MAIN_MENU_PREFIXES:-}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
COMPOSE_CMD=""

prompt_required() {
  local label="$1"
  local default_value="${2:-}"
  local reply

  while true; do
    if [[ -n "${default_value}" ]]; then
      read -r -p "${label} [${default_value}]: " reply
      reply="${reply:-${default_value}}"
    else
      read -r -p "${label}: " reply
    fi

    if [[ -n "${reply}" ]]; then
      printf '%s\n' "${reply}"
      return 0
    fi

    echo "A value is required."
  done
}

prompt_yes_no() {
  local label="$1"
  local default_value="$2"
  local reply

  while true; do
    read -r -p "${label} [${default_value}]: " reply
    reply="${reply:-${default_value}}"
    case "${reply}" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO)
        return 1
        ;;
      *)
        echo "Answer y or n."
        ;;
    esac
  done
}

extract_private_key() {
  local file_path="$1"
  awk '$1 == "PrivateKey" && $2 == "=" { print $3; exit }' "${file_path}"
}

set_private_key() {
  local file_path="$1"
  local key_value="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="${key_value}" '
    $1 == "PrivateKey" && $2 == "=" {
      print "PrivateKey = " key
      next
    }
    { print }
  ' "${file_path}" > "${tmp_file}"
  mv "${tmp_file}" "${file_path}"
}

ensure_wg_key_tool() {
  if command -v wg >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if prompt_yes_no "'wg' tool not found. Install wireguard-tools now?" "y"; then
      if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y wireguard-tools
      else
        apt-get update
        apt-get install -y wireguard-tools
      fi
    fi
  fi

  if ! command -v wg >/dev/null 2>&1; then
    echo "wireguard-tools is required to auto-generate HUB private keys." >&2
    echo "Install it and re-run, or set private keys manually in active configs." >&2
    exit 1
  fi
}

store_keypair_files() {
  local private_key="$1"
  local private_key_path="$2"
  local public_key_path="$3"
  local profile_label="$4"
  local public_key

  public_key="$(printf '%s' "${private_key}" | wg pubkey)"

  printf '%s\n' "${private_key}" > "${private_key_path}"
  printf '%s\n' "${public_key}" > "${public_key_path}"
  chmod 600 "${private_key_path}" "${public_key_path}"

  echo "Stored ${profile_label} HUB private/public key files."
  echo "  ${private_key_path}"
  echo "  ${public_key_path}"
}

rotate_hub_keys() {
  local trusted_key
  local untrusted_key
  local rotate_trusted="false"
  local rotate_untrusted="false"

  echo "WARNING: Rotating a HUB key requires updating all matching spoke profiles with the new HUB public key."

  if prompt_yes_no "Rotate trusted HUB key?" "n"; then
    rotate_trusted="true"
  fi

  if prompt_yes_no "Rotate untrusted HUB key?" "n"; then
    rotate_untrusted="true"
  fi

  if [[ "${rotate_trusted}" != "true" && "${rotate_untrusted}" != "true" ]]; then
    echo "Key rotation cancelled."
    exit 1
  fi

  ensure_wg_key_tool

  if [[ "${rotate_trusted}" == "true" ]]; then
    trusted_key="$(wg genkey)"
    set_private_key "${TRUSTED_ACTIVE}" "${trusted_key}"
    store_keypair_files "${trusted_key}" "${TRUSTED_PRIVATE_KEY_FILE}" "${TRUSTED_PUBLIC_KEY_FILE}" "trusted"
    echo "Generated new trusted HUB keypair."
  fi

  if [[ "${rotate_untrusted}" == "true" ]]; then
    untrusted_key="$(wg genkey)"
    set_private_key "${UNTRUSTED_ACTIVE}" "${untrusted_key}"
    store_keypair_files "${untrusted_key}" "${UNTRUSTED_PRIVATE_KEY_FILE}" "${UNTRUSTED_PUBLIC_KEY_FILE}" "untrusted"
    echo "Generated new untrusted HUB keypair."
  fi
}

get_public_key_value() {
  local active_conf_path="$1"
  local public_key_path="$2"
  local public_key
  local private_key

  if [[ -s "${public_key_path}" ]]; then
    awk 'NF { print; exit }' "${public_key_path}"
    return 0
  fi

  [[ -f "${active_conf_path}" ]] || return 1

  private_key="$(extract_private_key "${active_conf_path}")"
  if [[ -z "${private_key}" || "${private_key}" == "<HUB_TRUSTED_PRIVATE_KEY>" || "${private_key}" == "<HUB_UNTRUSTED_PRIVATE_KEY>" ]]; then
    return 1
  fi

  command -v wg >/dev/null 2>&1 || return 2

  public_key="$(printf '%s' "${private_key}" | wg pubkey)"
  printf '%s\n' "${public_key}"
}

print_hub_public_keys() {
  local trusted_public_key=""
  local untrusted_public_key=""

  trusted_public_key="$(get_public_key_value "${TRUSTED_ACTIVE}" "${TRUSTED_PUBLIC_KEY_FILE}" 2>/dev/null || true)"
  untrusted_public_key="$(get_public_key_value "${UNTRUSTED_ACTIVE}" "${UNTRUSTED_PUBLIC_KEY_FILE}" 2>/dev/null || true)"

  echo "HUB public keys for spoke assignment:"
  if [[ -n "${trusted_public_key}" ]]; then
    echo "TRUSTED:   ${trusted_public_key}"
  else
    echo "TRUSTED:   unavailable (run deploy once, or ensure wg is installed to derive from private key)"
  fi

  if [[ -n "${untrusted_public_key}" ]]; then
    echo "UNTRUSTED: ${untrusted_public_key}"
  else
    echo "UNTRUSTED: unavailable (run deploy once, or ensure wg is installed to derive from private key)"
  fi
}

get_interface_value() {
  local file_path="$1"
  local key_name="$2"

  awk -v key_name="${key_name}" '$1 == key_name && $2 == "=" { print $3; exit }' "${file_path}"
}

print_deployment_summary() {
  local trusted_address
  local untrusted_address
  local trusted_port
  local untrusted_port

  trusted_address="$(get_interface_value "${TRUSTED_ACTIVE}" "Address")"
  untrusted_address="$(get_interface_value "${UNTRUSTED_ACTIVE}" "Address")"
  trusted_port="$(get_interface_value "${TRUSTED_ACTIVE}" "ListenPort")"
  untrusted_port="$(get_interface_value "${UNTRUSTED_ACTIVE}" "ListenPort")"

  echo
  echo "Deployment summary:"
  echo "Trusted profile:"
  echo "  tunnel address: ${trusted_address}"
  echo "  listen port:    ${trusted_port}/udp"
  echo "  SSH access:     allowed to ConsolePi"
  echo "Untrusted profile:"
  echo "  tunnel address: ${untrusted_address}"
  echo "  listen port:    ${untrusted_port}/udp"
  echo "  SSH access:     blocked to ConsolePi"

  if [[ -n "${MGMT_SSH_PORT:-}" ]]; then
    echo "Direct management SSH port: ${MGMT_SSH_PORT}/tcp"
  else
    echo "Direct management SSH port: 2222/tcp"
  fi

  print_hub_public_keys
}

bootstrap_missing_private_keys() {
  local trusted_key
  local untrusted_key

  trusted_key="$(extract_private_key "${TRUSTED_ACTIVE}")"
  untrusted_key="$(extract_private_key "${UNTRUSTED_ACTIVE}")"

  if [[ "${trusted_key}" != "<HUB_TRUSTED_PRIVATE_KEY>" && "${untrusted_key}" != "<HUB_UNTRUSTED_PRIVATE_KEY>" ]]; then
    return 0
  fi

  echo "One or more HUB private key placeholders are still present. Generating missing HUB keys automatically."

  ensure_wg_key_tool

  if [[ "${trusted_key}" == "<HUB_TRUSTED_PRIVATE_KEY>" ]]; then
    trusted_key="$(wg genkey)"
    set_private_key "${TRUSTED_ACTIVE}" "${trusted_key}"
    store_keypair_files "${trusted_key}" "${TRUSTED_PRIVATE_KEY_FILE}" "${TRUSTED_PUBLIC_KEY_FILE}" "trusted"
    echo "Generated trusted HUB private key."
  fi

  if [[ "${untrusted_key}" == "<HUB_UNTRUSTED_PRIVATE_KEY>" ]]; then
    untrusted_key="$(wg genkey)"
    set_private_key "${UNTRUSTED_ACTIVE}" "${untrusted_key}"
    store_keypair_files "${untrusted_key}" "${UNTRUSTED_PRIVATE_KEY_FILE}" "${UNTRUSTED_PUBLIC_KEY_FILE}" "untrusted"
    echo "Generated untrusted HUB private key."
  fi
}

sync_profile() {
  local example_file="$1"
  local active_file="$2"
  local tmp_file

  [[ -f "${active_file}" ]] || {
    cp "${example_file}" "${active_file}"
    return 0
  }

  cp "${active_file}" "${active_file}.bak.${TIMESTAMP}"
  tmp_file="$(mktemp)"

  awk '
    FNR == NR {
      if ($1 == "PrivateKey" && $2 == "=" && $3 !~ /^</) {
        private_key = $3
      }
      if ($1 == "PublicKey" && $2 == "=") {
        current_pk = $3
        next
      }
      if ($1 == "AllowedIPs" && $2 == "=") {
        ip = $3
        sub(/\/32$/, "", ip)
        if (current_pk != "" && current_pk !~ /^</) {
          peer_pk[ip] = current_pk
        }
        current_pk = ""
      }
      next
    }

    {
      if ($1 == "PrivateKey" && $2 == "=") {
        if (private_key != "") {
          print "PrivateKey = " private_key
        } else {
          print
        }
        next
      }

      if ($1 == "PublicKey" && $2 == "=" && $3 ~ /^</) {
        pending_pub = 1
        pending_line = $0
        next
      }

      if (pending_pub && $1 == "AllowedIPs" && $2 == "=") {
        ip = $3
        sub(/\/32$/, "", ip)
        if (ip in peer_pk) {
          print "PublicKey = " peer_pk[ip]
        } else {
          print pending_line
        }
        print
        pending_pub = 0
        pending_line = ""
        next
      }

      if (pending_pub) {
        print pending_line
        pending_pub = 0
        pending_line = ""
      }

      print
    }

    END {
      if (pending_pub) {
        print pending_line
      }
    }
  ' "${active_file}" "${example_file}" > "${tmp_file}"

  mv "${tmp_file}" "${active_file}"
}

usage() {
  cat <<EOF
Usage: ./deploy-hub.sh [options]

Options:
  --without-consolepi Skip starting the consolepi service
  --refresh-configs  Recreate active wg config files from examples (backs up existing files)
  --new-keys         Prompt separately for trusted and untrusted HUB key rotation
  --get-keys         Print current HUB trusted and untrusted public keys and exit
  --get-hosts        Update ConsolePi HOSTS from /etc/hosts (SSH only, no pinned username) and exit
  --print-hosts      Print ConsolePi HOSTS from /etc/hosts (no file changes)
  --help             Show this help
EOF
}

load_env_if_present() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}

upsert_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file

  if [[ ! -f "${ENV_FILE}" ]]; then
    cat > "${ENV_FILE}" <<'EOF'
# HUB connection values. Optional overrides such as ports can be added later.

MGMT_SSH_PORT=2222
MGMT_ALLOWED_DIRECT_SSH=0.0.0.0/0

WG_TRUSTED_SUBNET=
WG_UNTRUSTED_SUBNET=

WG_TRUSTED_PEER_KEY_1=
WG_TRUSTED_PEER_KEY_2=
WG_TRUSTED_PEER_KEY_3=

WG_UNTRUSTED_PEER_KEY_1=
WG_UNTRUSTED_PEER_KEY_2=
WG_UNTRUSTED_PEER_KEY_3=
EOF
  fi

  tmp_file="$(mktemp)"

  if grep -qE "^${key}=" "${ENV_FILE}"; then
    awk -F= -v key="${key}" -v value="${value}" '
      BEGIN { replaced = 0 }
      $1 == key {
        print key "=" value
        replaced = 1
        next
      }
      { print }
      END {
        if (!replaced) {
          print key "=" value
        }
      }
    ' "${ENV_FILE}" > "${tmp_file}"
  else
    cat "${ENV_FILE}" > "${tmp_file}"
    [[ -s "${tmp_file}" ]] && printf '\n' >> "${tmp_file}"
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${ENV_FILE}"
}

ensure_required_env_values() {
  load_env_if_present

  if [[ -z "${WG_TRUSTED_SUBNET:-}" ]]; then
    WG_TRUSTED_SUBNET="$(prompt_required "Trusted WireGuard subnet (/24)" "10.99.99.0/24")"
    upsert_env_value "WG_TRUSTED_SUBNET" "${WG_TRUSTED_SUBNET}"
  fi

  if [[ -z "${WG_UNTRUSTED_SUBNET:-}" ]]; then
    WG_UNTRUSTED_SUBNET="$(prompt_required "Untrusted WireGuard subnet (/24)" "10.99.98.0/24")"
    upsert_env_value "WG_UNTRUSTED_SUBNET" "${WG_UNTRUSTED_SUBNET}"
  fi

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

build_main_menu_prefix_regex() {
  local raw_prefixes="$1"
  local regex=""
  local prefix
  local escaped
  local prefixes

  IFS=',' read -r -a prefixes <<< "${raw_prefixes}"
  for prefix in "${prefixes[@]}"; do
    prefix="${prefix#${prefix%%[![:space:]]*}}"
    prefix="${prefix%${prefix##*[![:space:]]}}"
    prefix="$(printf '%s' "${prefix}" | tr '[:upper:]' '[:lower:]')"
    [[ -n "${prefix}" ]] || continue

    escaped="$(printf '%s' "${prefix}" | sed -E 's/[][(){}.+*?^$|\\]/\\&/g')"
    if [[ -n "${regex}" ]]; then
      regex+="|"
    fi
    regex+="^${escaped}"
  done

  printf '%s' "${regex}"
}

generate_consolepi_hosts_entries() {
  local output_file="$1"
  local allow_empty="${2:-true}"
  local hosts_file="/etc/hosts"
  local tmp_pairs
  local pair_count
  local main_menu_prefix_regex

  if [[ ! -r "${hosts_file}" ]]; then
    echo "Unable to read ${hosts_file}" >&2
    exit 1
  fi

  main_menu_prefix_regex="$(build_main_menu_prefix_regex "${HOSTS_MAIN_MENU_PREFIXES}")"

  tmp_pairs="$(mktemp)"

  awk '
    /^[[:space:]]*#/ || NF < 2 { next }
    $1 ~ /:/ { next }
    $1 ~ /^(127\.|0\.0\.0\.0)$/ { next }
    $1 == "255.255.255.255" { next }
    tolower($2) ~ /^localhost(\.|$)/ { next }
    tolower($2) ~ /^broadcasthost(\.|$)/ { next }
    {
      ip = $1
      host = $2
      gsub(/[^A-Za-z0-9_.()-]/, "_", host)
      if (host in seen) {
        next
      }
      seen[host] = 1
      print host "\t" ip
    }
  ' "${hosts_file}" > "${tmp_pairs}"

  pair_count="$(wc -l < "${tmp_pairs}" | tr -d '[:space:]')"
  if [[ "${pair_count}" == "0" ]]; then
    rm -f "${tmp_pairs}"
    if [[ "${allow_empty}" == "true" ]]; then
      printf '  {}\n' > "${output_file}"
      return 0
    fi
    return 10
  fi

  sort -f "${tmp_pairs}" | awk -F '\t' -v main_menu_re="${main_menu_prefix_regex}" '
    {
      host = $1
      ip = $2
      show_in_main = "false"
      if (main_menu_re != "" && tolower(host) ~ main_menu_re) {
        show_in_main = "true"
      }
      print "  " host ":"
      print "    address: " ip ":22"
      print "    method: ssh"
      print "    show_in_main: " show_in_main
      print "    group: Imported"
    }
  ' > "${output_file}"

  rm -f "${tmp_pairs}"
}

update_consolepi_hosts_from_etc_hosts() {
  local config_file="${CONSOLEPI_RUNTIME_CONFIG_FILE}"
  local tmp_entries
  local tmp_output

  if [[ ! -f "${config_file}" ]]; then
    echo "Missing ${config_file}" >&2
    exit 1
  fi

  tmp_entries="$(mktemp)"
  tmp_output="$(mktemp)"

  if ! generate_consolepi_hosts_entries "${tmp_entries}" "false"; then
    rm -f "${tmp_entries}" "${tmp_output}"
    echo "No valid non-loopback IPv4 host entries were found in /etc/hosts; refusing to update HOSTS." >&2
    exit 1
  fi

  cp "${config_file}" "${config_file}.bak.${TIMESTAMP}"

  awk -v entries_file="${tmp_entries}" '
    BEGIN {
      in_hosts = 0
      hosts_replaced = 0
    }

    {
      if (!in_hosts && $0 ~ /^HOSTS:[[:space:]]*$/) {
        print "HOSTS:"
        while ((getline entry < entries_file) > 0) {
          print entry
        }
        close(entries_file)
        in_hosts = 1
        hosts_replaced = 1
        next
      }

      if (in_hosts) {
        if (
          $0 ~ /^[^[:space:]#][^:]*:[[:space:]]*($|#)/ ||
          $0 ~ /^---[[:space:]]*$/ ||
          $0 ~ /^\.\.\.[[:space:]]*$/
        ) {
          in_hosts = 0
          print
          next
        }
        next
      }

      print
    }

    END {
      if (!hosts_replaced) {
        print "HOSTS:"
        while ((getline entry < entries_file) > 0) {
          print entry
        }
        close(entries_file)
      }
    }
  ' "${config_file}" > "${tmp_output}"

  mv "${tmp_output}" "${config_file}"
  rm -f "${tmp_entries}"

  echo "Updated HOSTS in ${config_file}"
  echo "Backup saved to ${config_file}.bak.${TIMESTAMP}"
}

print_consolepi_hosts_from_etc_hosts() {
  local tmp_entries

  tmp_entries="$(mktemp)"
  generate_consolepi_hosts_entries "${tmp_entries}" "true"

  echo "HOSTS:"
  cat "${tmp_entries}"

  rm -f "${tmp_entries}"
}

seed_consolepi_remote_cache() {
  mkdir -p "${CONSOLEPI_RUNTIME_DIR}"

  if ! command -v python3 >/dev/null 2>&1; then
  echo "WARNING: python3 not found on host, skipping static ConsolePi remote cache generation." >&2
  return 0
  fi

  CONSOLEPI_CLOUD_CACHE_FILE="${CONSOLEPI_CLOUD_CACHE_FILE}" python3 - <<'PY'
import json
import os
import re
import time


def derive_peer_ip(subnet: str, peer_index: int) -> str:
  base_ip, prefix = subnet.split("/", 1)
  if prefix != "24":
    raise ValueError(f"Only /24 subnets are supported for static cache generation: {subnet}")
  octets = base_ip.split(".")
  if len(octets) != 4:
    raise ValueError(f"Invalid subnet: {subnet}")
  host_octet = 10 + peer_index
  if not 11 <= host_octet <= 254:
    raise ValueError(f"Peer index out of supported range: {peer_index}")
  return f"{octets[0]}.{octets[1]}.{octets[2]}.{host_octet}"


def build_entries(prefix: str, profile: str, subnet: str):
  entries = {}
  now = int(time.time())
  pattern = re.compile(rf"^{re.escape(prefix)}_(\d+)$")
  for key, value in sorted(os.environ.items()):
    match = pattern.match(key)
    if not match:
      continue
    value = value.strip()
    if not value:
      continue
    idx = int(match.group(1))
    peer_ip = derive_peer_ip(subnet, idx)
    host = f"spoke-{profile}-{idx}"
    entries[host] = {
      "adapters": {},
      "api_port": 5000,
      "interfaces": {
        profile: {
          "ip": peer_ip,
          "isgw": False,
          "mac": None,
        }
      },
      "last_ip": peer_ip,
      "rem_ip": peer_ip,
      "source": "static",
      "upd_time": now,
      "user": "consolepi",
    }
  return entries


cache_file = os.environ["CONSOLEPI_CLOUD_CACHE_FILE"]
trusted_subnet = os.environ.get("WG_TRUSTED_SUBNET", "")
untrusted_subnet = os.environ.get("WG_UNTRUSTED_SUBNET", "")

data = {}
if trusted_subnet:
  data.update(build_entries("WG_TRUSTED_PEER_KEY", "wg-trusted", trusted_subnet))
if untrusted_subnet:
  data.update(build_entries("WG_UNTRUSTED_PEER_KEY", "wg-untrusted", untrusted_subnet))

with open(cache_file, "w", encoding="utf-8") as f:
  json.dump(data, f, indent=2, sort_keys=True)
  f.write("\n")

print(f"Wrote static ConsolePi remote cache: {cache_file} ({len(data)} entries)")
PY
}

for arg in "$@"; do
  case "$arg" in
    --without-consolepi)
      WITH_CONSOLEPI="false"
      ;;
    --refresh-configs)
      REFRESH_CONFIGS="true"
      ;;
    --new-keys)
      ROTATE_KEYS="true"
      ;;
    --get-keys)
      PRINT_KEYS="true"
      ;;
    --get-hosts)
      PRINT_HOSTS="true"
      ;;
    --print-hosts)
      PRINT_HOSTS_ONLY="true"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${PRINT_KEYS}" == "true" ]]; then
  print_hub_public_keys
  exit 0
fi

if [[ "${PRINT_HOSTS_ONLY}" == "true" ]]; then
  load_env_if_present
  print_consolepi_hosts_from_etc_hosts
  exit 0
fi

if [[ "${PRINT_HOSTS}" == "true" ]]; then
  load_env_if_present
  update_consolepi_hosts_from_etc_hosts
  exit 0
fi

ensure_required_env_values

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "Docker Compose is required (docker compose or docker-compose)." >&2
  exit 1
fi

chmod +x "${RENDER_SCRIPT}"
"${RENDER_SCRIPT}"
seed_consolepi_remote_cache

if [[ "${REFRESH_CONFIGS}" == "true" ]]; then
  if [[ -f "${TRUSTED_ACTIVE}" ]]; then
    cp "${TRUSTED_ACTIVE}" "${TRUSTED_ACTIVE}.bak.${TIMESTAMP}"
  fi
  if [[ -f "${UNTRUSTED_ACTIVE}" ]]; then
    cp "${UNTRUSTED_ACTIVE}" "${UNTRUSTED_ACTIVE}.bak.${TIMESTAMP}"
  fi
  cp "${TRUSTED_EXAMPLE}" "${TRUSTED_ACTIVE}"
  cp "${UNTRUSTED_EXAMPLE}" "${UNTRUSTED_ACTIVE}"
else
  sync_profile "${TRUSTED_EXAMPLE}" "${TRUSTED_ACTIVE}"
  sync_profile "${UNTRUSTED_EXAMPLE}" "${UNTRUSTED_ACTIVE}"
fi

chmod 700 "${SCRIPT_DIR}/wireguard/trusted/config" "${SCRIPT_DIR}/wireguard/trusted/config/wg_confs"
chmod 700 "${SCRIPT_DIR}/wireguard/untrusted/config" "${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs"
chmod 600 "${TRUSTED_ACTIVE}" "${UNTRUSTED_ACTIVE}"

if [[ "${ROTATE_KEYS}" == "true" ]]; then
  rotate_hub_keys
fi

bootstrap_missing_private_keys

if grep -q "<HUB_.*PRIVATE_KEY>" "${TRUSTED_ACTIVE}" || \
  grep -q "<HUB_.*PRIVATE_KEY>" "${UNTRUSTED_ACTIVE}"; then
  echo "Active WireGuard config still has placeholder HUB private keys." >&2
  echo "Set real private keys before deploy:" >&2
  echo "  ${TRUSTED_ACTIVE}" >&2
  echo "  ${UNTRUSTED_ACTIVE}" >&2
  exit 1
fi

trusted_missing="$(grep -cE "<TRUSTED_PEER_[0-9]+_PUBLIC_KEY>" "${TRUSTED_ACTIVE}" || true)"
untrusted_missing="$(grep -cE "<UNTRUSTED_PEER_[0-9]+_PUBLIC_KEY>" "${UNTRUSTED_ACTIVE}" || true)"

if (( trusted_missing > 0 || untrusted_missing > 0 )); then
  echo "WARNING: Some peer public key placeholders are still present." >&2
  echo "Trusted missing keys: ${trusted_missing}" >&2
  echo "Untrusted missing keys: ${untrusted_missing}" >&2
  echo "Existing peers with real keys will still run; new placeholder peers will not handshake until keys are set." >&2
fi

${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d wireguard-hub

if [[ "${WITH_CONSOLEPI}" == "true" ]]; then
  ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d --force-recreate consolepi
fi

${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" ps
${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" logs --tail=40 wireguard-hub

echo
echo "HUB deployment complete."
if [[ "${WITH_CONSOLEPI}" == "true" ]]; then
  echo "ConsolePi service started."
else
  echo "ConsolePi service skipped by request (--without-consolepi)."
fi

print_deployment_summary
