#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${HUB_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/render-profile-configs.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN="false"

PROFILE=""
SLOT=""
PEER_NAME=""
PUBLIC_KEY=""

usage() {
  cat <<EOF
Usage: ./wireguard/register-peer.sh [options]

Options:
  --profile trusted|untrusted
  --slot N                  Peer slot index (N maps to host .(10 + N))
  --peer-name NAME          Optional label used in comments/snippet filename
  --public-key KEY
  --dry-run
  --help
EOF
}

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
      printf '%s' "${reply}"
      return 0
    fi

    echo "A value is required."
  done
}

validate_public_key() {
  local key="$1"
  [[ "${key}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  ((${#key} >= 40))
}

validate_slot() {
  local slot="$1"
  [[ "${slot}" =~ ^[0-9]+$ ]] || return 1
  ((slot >= 1 && slot <= 254))
}

get_env_value() {
  local key="$1"
  local line

  line="$(grep -E "^${key}=" "${ENV_FILE}" || true)"
  printf '%s' "${line#*=}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (updated == 0) {
        print key "=" value
      }
    }
  ' "${ENV_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${ENV_FILE}"
}

derive_peer_ip_from_subnet() {
  local subnet="$1"
  local slot="$2"
  local base_ip
  local prefix
  local o1
  local o2
  local o3
  local o4
  local host_octet

  base_ip="${subnet%/*}"
  prefix="${subnet#*/}"

  if [[ "${prefix}" != "24" ]]; then
    echo "Only /24 subnets are supported for slot-derived peers: ${subnet}" >&2
    exit 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "${base_ip}"
  host_octet=$((10 + slot))
  if ((host_octet < 11 || host_octet > 254)); then
    echo "Derived host octet out of range for slot ${slot}: ${host_octet}" >&2
    exit 1
  fi

  printf '%s.%s.%s.%s' "${o1}" "${o2}" "${o3}" "${host_octet}"
}

find_first_empty_slot() {
  local key_prefix="$1"
  local slot
  local key_var
  local key_val

  for slot in $(seq 1 254); do
    key_var="${key_prefix}_${slot}"
    key_val="$(get_env_value "${key_var}")"
    key_val="${key_val//[[:space:]]/}"
    if [[ -z "${key_val}" ]]; then
      printf '%s' "${slot}"
      return 0
    fi
  done

  return 1
}

slugify() {
  local value="$1"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "${value}" | tr -cs 'a-z0-9' '-')"
  value="${value#-}"
  value="${value%-}"
  printf '%s' "${value:-peer}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --slot)
      SLOT="${2:-}"
      shift 2
      ;;
    --peer-name)
      PEER_NAME="${2:-}"
      shift 2
      ;;
    --public-key)
      PUBLIC_KEY="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || {
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
}

[[ -f "${RENDER_SCRIPT}" ]] || {
  echo "Missing ${RENDER_SCRIPT}." >&2
  exit 1
}

if [[ -z "${PROFILE}" ]]; then
  PROFILE="$(prompt_required "Profile class (trusted/untrusted)" "untrusted")"
fi

case "${PROFILE}" in
  trusted)
    PEER_KEY_PREFIX="WG_TRUSTED_PEER_KEY"
    SUBNET_VAR="WG_TRUSTED_SUBNET"
    ACTIVE_CONF="${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf"
    SNIPPET_PREFIX="trusted"
    ;;
  untrusted)
    PEER_KEY_PREFIX="WG_UNTRUSTED_PEER_KEY"
    SUBNET_VAR="WG_UNTRUSTED_SUBNET"
    ACTIVE_CONF="${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf"
    SNIPPET_PREFIX="untrusted"
    ;;
  *)
    echo "Profile must be trusted or untrusted." >&2
    exit 1
    ;;
esac

if [[ -z "${SLOT}" ]]; then
  SLOT="$(find_first_empty_slot "${PEER_KEY_PREFIX}" || true)"
  if [[ -z "${SLOT}" ]]; then
    SLOT="$(prompt_required "Peer slot index (1-254)")"
  else
    echo "Using first empty slot: ${SLOT}"
  fi
fi
validate_slot "${SLOT}" || {
  echo "Slot must be an integer in range 1-254." >&2
  exit 1
}

if [[ -z "${PUBLIC_KEY}" ]]; then
  PUBLIC_KEY="$(prompt_required "Peer public key")"
fi
validate_public_key "${PUBLIC_KEY}" || {
  echo "Public key format looks invalid." >&2
  exit 1
}

if [[ -z "${PEER_NAME}" ]]; then
  PEER_NAME="spoke-${PROFILE}-${SLOT}"
fi

SUBNET_VALUE="$(get_env_value "${SUBNET_VAR}")"
[[ -n "${SUBNET_VALUE}" ]] || {
  echo "Missing ${SUBNET_VAR} in ${ENV_FILE}" >&2
  exit 1
}

PEER_IP="$(derive_peer_ip_from_subnet "${SUBNET_VALUE}" "${SLOT}")"
PEER_KEY_VAR="${PEER_KEY_PREFIX}_${SLOT}"
CURRENT_KEY="$(get_env_value "${PEER_KEY_VAR}")"
CURRENT_KEY="${CURRENT_KEY//[[:space:]]/}"

if [[ -f "${ACTIVE_CONF}" ]]; then
  grep -Fq "PublicKey = ${PUBLIC_KEY}" "${ACTIVE_CONF}" && {
    echo "Public key already exists in ${ACTIVE_CONF}." >&2
    exit 1
  }
fi

PEER_STANZA="[Peer]
# ${PEER_NAME}
PublicKey = ${PUBLIC_KEY}
AllowedIPs = ${PEER_IP}/32
PersistentKeepalive = 25"

SNIPPET_DIR="${SCRIPT_DIR}/profiles"
SNIPPET_PATH="${SNIPPET_DIR}/peer-${SNIPPET_PREFIX}-$(slugify "${PEER_NAME}").conf.snippet"

echo "Registering ${PROFILE} peer ${PEER_NAME} (slot ${SLOT}, ${PEER_IP})"

if [[ "${DRY_RUN}" == "true" ]]; then
  if [[ -n "${CURRENT_KEY}" ]]; then
    echo "Would replace ${PEER_KEY_VAR} in ${ENV_FILE}"
  else
    echo "Would set ${PEER_KEY_VAR} in ${ENV_FILE}"
  fi
  echo "Would rerender templates via ${RENDER_SCRIPT}"
  if [[ -f "${ACTIVE_CONF}" ]]; then
    echo "Would append peer stanza to ${ACTIVE_CONF}"
  else
    echo "Would write snippet to ${SNIPPET_PATH} because ${ACTIVE_CONF} does not exist"
  fi
  printf '\n%s\n' "${PEER_STANZA}"
  exit 0
fi

ENV_BACKUP="${ENV_FILE}.bak.${TIMESTAMP}"
cp "${ENV_FILE}" "${ENV_BACKUP}"

set_env_value "${PEER_KEY_VAR}" "${PUBLIC_KEY}"

if ! bash "${RENDER_SCRIPT}"; then
  cp "${ENV_BACKUP}" "${ENV_FILE}"
  echo "Render failed. Restored ${ENV_FILE} from backup." >&2
  exit 1
fi

mkdir -p "${SNIPPET_DIR}"
printf '%s\n' "${PEER_STANZA}" > "${SNIPPET_PATH}"

if [[ -f "${ACTIVE_CONF}" ]]; then
  cp "${ACTIVE_CONF}" "${ACTIVE_CONF}.bak.${TIMESTAMP}"
  if ! grep -Fq "AllowedIPs = ${PEER_IP}/32" "${ACTIVE_CONF}"; then
    printf '\n%s\n' "${PEER_STANZA}" >> "${ACTIVE_CONF}"
  fi
  echo "Updated ${ACTIVE_CONF}"
  echo "Restart or reload wireguard-hub to apply the new peer."
else
  echo "Active config ${ACTIVE_CONF} does not exist yet."
  echo "Wrote peer snippet to ${SNIPPET_PATH}"
fi

echo "Updated ${PEER_KEY_VAR} in ${ENV_FILE}"
echo "Peer snippet saved at ${SNIPPET_PATH}"
