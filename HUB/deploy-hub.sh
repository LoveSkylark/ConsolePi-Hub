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
WITH_CONSOLEPI="true"
REFRESH_CONFIGS="false"
ROTATE_KEYS="false"
PRINT_KEYS="false"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
COMPOSE_CMD=""

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

  echo "WARNING: This will rotate HUB trusted and untrusted private keys."
  echo "All spoke profiles must be updated with the new HUB public keys or tunnels will fail."
  if ! prompt_yes_no "Continue with key rotation?" "n"; then
    echo "Key rotation cancelled."
    exit 1
  fi

  ensure_wg_key_tool

  trusted_key="$(wg genkey)"
  untrusted_key="$(wg genkey)"

  set_private_key "${TRUSTED_ACTIVE}" "${trusted_key}"
  set_private_key "${UNTRUSTED_ACTIVE}" "${untrusted_key}"

  store_keypair_files "${trusted_key}" "${TRUSTED_PRIVATE_KEY_FILE}" "${TRUSTED_PUBLIC_KEY_FILE}" "trusted"
  store_keypair_files "${untrusted_key}" "${UNTRUSTED_PRIVATE_KEY_FILE}" "${UNTRUSTED_PUBLIC_KEY_FILE}" "untrusted"

  echo "Generated new trusted and untrusted HUB keypairs."
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

bootstrap_missing_private_keys() {
  local trusted_key
  local untrusted_key

  trusted_key="$(extract_private_key "${TRUSTED_ACTIVE}")"
  untrusted_key="$(extract_private_key "${UNTRUSTED_ACTIVE}")"

  if [[ "${trusted_key}" != "<HUB_TRUSTED_PRIVATE_KEY>" && "${untrusted_key}" != "<HUB_UNTRUSTED_PRIVATE_KEY>" ]]; then
    return 0
  fi

  echo "One or more HUB private key placeholders are still present."
  if ! prompt_yes_no "Generate missing HUB private keys now?" "y"; then
    echo "Set private keys manually before deploy:" >&2
    echo "  ${TRUSTED_ACTIVE}" >&2
    echo "  ${UNTRUSTED_ACTIVE}" >&2
    exit 1
  fi

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
  --new-keys         Rotate HUB trusted and untrusted keypairs after warning prompt
  --get-keys         Print current HUB trusted and untrusted public keys and exit
  --help             Show this help
EOF
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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

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
