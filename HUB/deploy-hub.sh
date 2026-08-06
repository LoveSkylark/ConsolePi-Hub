#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/wireguard/render-profile-configs.sh"
TRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf.example"
UNTRUSTED_EXAMPLE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf.example"
TRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/trusted/config/wg_confs/wg-trusted.conf"
UNTRUSTED_ACTIVE="${SCRIPT_DIR}/wireguard/untrusted/config/wg_confs/wg-untrusted.conf"
WITH_CONSOLEPI="false"
REFRESH_CONFIGS="false"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
COMPOSE_CMD=""

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
  --with-consolepi   Also start the consolepi profile service
  --refresh-configs  Recreate active wg config files from examples (backs up existing files)
  --help             Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --with-consolepi)
      WITH_CONSOLEPI="true"
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
  echo "ConsolePi service not started. Re-run with --with-consolepi to start it."
fi
