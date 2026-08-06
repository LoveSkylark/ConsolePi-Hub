#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/wireguard/render-profile-configs.sh"
TRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf.example"
UNTRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf.example"
TRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf"
UNTRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf"
WITH_CONSOLEPI="true"
REFRESH_CONFIGS="false"
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
    echo "Generated trusted HUB private key."
  fi

  if [[ "${untrusted_key}" == "<HUB_UNTRUSTED_PRIVATE_KEY>" ]]; then
    untrusted_key="$(wg genkey)"
    set_private_key "${UNTRUSTED_ACTIVE}" "${untrusted_key}"
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
  --without-consolepi Skip starting the consolepi profile service
  --refresh-configs  Recreate active wg config files from examples (backs up existing files)
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

${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d wireguard-trusted wireguard-untrusted

if [[ "${WITH_CONSOLEPI}" == "true" ]]; then
  ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" --profile consolepi up -d consolepi
fi

${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" ps
${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" logs --tail=40 wireguard-trusted wireguard-untrusted

echo
echo "HUB deployment complete."
if [[ "${WITH_CONSOLEPI}" == "true" ]]; then
  echo "ConsolePi service started."
else
  echo "ConsolePi service skipped by request (--without-consolepi)."
fi
