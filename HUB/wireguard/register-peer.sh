#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${HUB_DIR}/.env"
RENDER_SCRIPT="${SCRIPT_DIR}/render-profile-configs.sh"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN="false"
REPO_URL="${CONSOLEPI_HUB_REPO_URL:-https://github.com/LoveSkylark/ConsolePi-Hub}"
REPO_REF="${CONSOLEPI_HUB_REPO_REF:-main}"
RAW_BASE="${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_REF}"

PROFILE=""
PEER_NAME=""
PEER_IP=""
PUBLIC_KEY=""

usage() {
  cat <<EOF
Usage: ./wireguard/register-peer.sh [options]

Options:
  --profile trusted|untrusted
  --peer-name NAME
  --peer-ip IPv4
  --public-key KEY
  --dry-run
  --help
EOF
}

download_repo_file() {
  local repo_path="$1"
  local target_path="$2"
  local url="${RAW_BASE}/${repo_path}"

  mkdir -p "$(dirname "${target_path}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target_path}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "${url}" -O "${target_path}"
  else
    echo "Need curl or wget to pull missing files from ${REPO_URL}." >&2
    return 1
  fi
}

ensure_repo_asset() {
  local local_path="$1"
  local repo_path="$2"

  if [[ ! -f "${local_path}" ]]; then
    echo "Missing ${local_path}; pulling ${repo_path} from ${REPO_URL}@${REPO_REF}"
    download_repo_file "${repo_path}" "${local_path}"
  fi
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

validate_ipv4() {
  local ip="$1"
  local octet

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "${ip}"
  for octet in "${octets[@]}"; do
    ((octet >= 0 && octet <= 255)) || return 1
  done
}

validate_public_key() {
  local key="$1"
  [[ "${key}" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  ((${#key} >= 40))
}

csv_contains() {
  local csv="$1"
  local needle="$2"
  local item

  IFS=',' read -r -a items <<< "${csv}"
  for item in "${items[@]}"; do
    item="${item//[[:space:]]/}"
    [[ -n "${item}" ]] || continue
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

append_csv_value() {
  local csv="$1"
  local value="$2"

  if [[ -z "${csv//[[:space:]]/}" ]]; then
    printf '%s' "${value}"
  else
    printf '%s,%s' "${csv}" "${value}"
  fi
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
    --peer-name)
      PEER_NAME="${2:-}"
      shift 2
      ;;
    --peer-ip)
      PEER_IP="${2:-}"
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

ensure_repo_asset "${RENDER_SCRIPT}" "HUB/wireguard/render-profile-configs.sh"
chmod +x "${RENDER_SCRIPT}"

if [[ ! -f "${ENV_FILE}" && ! -f "${HUB_DIR}/.env.example" ]]; then
  echo "Missing ${HUB_DIR}/.env.example; pulling from ${REPO_URL}@${REPO_REF}"
  download_repo_file "HUB/.env.example" "${HUB_DIR}/.env.example" || true
fi

[[ -f "${ENV_FILE}" ]] || {
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
}

if [[ -z "${PROFILE}" ]]; then
  PROFILE="$(prompt_required "Profile class (trusted/untrusted)" "untrusted")"
fi

case "${PROFILE}" in
  trusted)
    PEER_VAR="WG_TRUSTED_PEER_IPS"
    OTHER_PEER_VAR="WG_UNTRUSTED_PEER_IPS"
    ACTIVE_CONF="${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf"
    EXAMPLE_CONF="${SCRIPT_DIR}/trusted/config/wg_confs/wg-trusted.conf.example"
    SNIPPET_PREFIX="trusted"
    SERVICE_NAME="wireguard-trusted"
    ;;
  untrusted)
    PEER_VAR="WG_UNTRUSTED_PEER_IPS"
    OTHER_PEER_VAR="WG_TRUSTED_PEER_IPS"
    ACTIVE_CONF="${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf"
    EXAMPLE_CONF="${SCRIPT_DIR}/untrusted/config/wg_confs/wg-untrusted.conf.example"
    SNIPPET_PREFIX="untrusted"
    SERVICE_NAME="wireguard-untrusted"
    ;;
  *)
    echo "Profile must be trusted or untrusted." >&2
    exit 1
    ;;
esac

if [[ -z "${PEER_NAME}" ]]; then
  PEER_NAME="$(prompt_required "Peer label" "spoke-${PROFILE}")"
fi

if [[ -z "${PEER_IP}" ]]; then
  PEER_IP="$(prompt_required "Peer tunnel IP")"
fi
validate_ipv4 "${PEER_IP}" || {
  echo "Peer IP must be a valid IPv4 address." >&2
  exit 1
}

if [[ -z "${PUBLIC_KEY}" ]]; then
  PUBLIC_KEY="$(prompt_required "Peer public key")"
fi
validate_public_key "${PUBLIC_KEY}" || {
  echo "Public key format looks invalid." >&2
  exit 1
}

CURRENT_CSV="$(get_env_value "${PEER_VAR}")"
OTHER_CSV="$(get_env_value "${OTHER_PEER_VAR}")"

csv_contains "${OTHER_CSV}" "${PEER_IP}" && {
  echo "Peer IP ${PEER_IP} already exists in ${OTHER_PEER_VAR}." >&2
  exit 1
}

if [[ -f "${ACTIVE_CONF}" ]]; then
  grep -Fq "PublicKey = ${PUBLIC_KEY}" "${ACTIVE_CONF}" && {
    echo "Public key already exists in ${ACTIVE_CONF}." >&2
    exit 1
  }
  grep -Fq "AllowedIPs = ${PEER_IP}/32" "${ACTIVE_CONF}" && {
    echo "Peer IP already exists in ${ACTIVE_CONF}." >&2
    exit 1
  }
fi

PEER_STANZA="[Peer]
# ${PEER_NAME}
PublicKey = ${PUBLIC_KEY}
AllowedIPs = ${PEER_IP}/32
PersistentKeepalive = 25"

if csv_contains "${CURRENT_CSV}" "${PEER_IP}"; then
  UPDATED_CSV="${CURRENT_CSV}"
else
  UPDATED_CSV="$(append_csv_value "${CURRENT_CSV}" "${PEER_IP}")"
fi

SNIPPET_DIR="${SCRIPT_DIR}/profiles"
SNIPPET_PATH="${SNIPPET_DIR}/peer-${SNIPPET_PREFIX}-$(slugify "${PEER_NAME}").conf.snippet"

echo "Registering ${PROFILE} peer ${PEER_NAME} (${PEER_IP})"

if [[ "${DRY_RUN}" == "true" ]]; then
  if [[ "${UPDATED_CSV}" != "${CURRENT_CSV}" ]]; then
    echo "Would update ${PEER_VAR}=${UPDATED_CSV}"
  else
    echo "${PEER_VAR} already contains ${PEER_IP}"
  fi
  echo "Would rerender ${EXAMPLE_CONF} via ${RENDER_SCRIPT}"
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

if [[ "${UPDATED_CSV}" != "${CURRENT_CSV}" ]]; then
  set_env_value "${PEER_VAR}" "${UPDATED_CSV}"
fi

if ! bash "${RENDER_SCRIPT}"; then
  cp "${ENV_BACKUP}" "${ENV_FILE}"
  echo "Render failed. Restored ${ENV_FILE} from backup." >&2
  exit 1
fi

mkdir -p "${SNIPPET_DIR}"
printf '%s\n' "${PEER_STANZA}" > "${SNIPPET_PATH}"

if [[ -f "${ACTIVE_CONF}" ]]; then
  cp "${ACTIVE_CONF}" "${ACTIVE_CONF}.bak.${TIMESTAMP}"
  printf '\n%s\n' "${PEER_STANZA}" >> "${ACTIVE_CONF}"
  echo "Updated ${ACTIVE_CONF}"
  echo "Restart or reload ${SERVICE_NAME} to apply the new peer."
else
  echo "Active config ${ACTIVE_CONF} does not exist yet."
  echo "Wrote peer snippet to ${SNIPPET_PATH}"
fi

echo "Updated ${PEER_VAR} in ${ENV_FILE}"
echo "Peer snippet saved at ${SNIPPET_PATH}"