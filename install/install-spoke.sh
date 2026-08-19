#!/usr/bin/env bash
set -euo pipefail

# Detects whether this host is a Raspberry Pi or a generic Debian-based
# machine, then fetches and runs the matching spoke installer:
#   Raspberry Pi   -> SPOKE/deploy-spoke.sh
#   Generic Debian -> SPOKE-Debian/deploy-spoke-debian.sh
# Override detection with CONSOLEPI_SPOKE_KIND=pi|debian.

REPO_URL="${CONSOLEPI_HUB_REPO_URL:-https://github.com/LoveSkylark/ConsolePi-Hub}"
REPO_REF="${CONSOLEPI_HUB_REPO_REF:-main}"
INSTALL_ROOT="${CONSOLEPI_SPOKE_ROOT:-${HOME}/ConnectPi-Spoke}"
HUB_KEY_FILE_NAME="hub_spoke_ed25519.pub"

detect_spoke_kind() {
  if [[ -n "${CONSOLEPI_SPOKE_KIND:-}" ]]; then
    printf '%s' "${CONSOLEPI_SPOKE_KIND}"
    return 0
  fi

  if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
    printf 'pi'
    return 0
  fi

  if [[ -f /proc/cpuinfo ]] && grep -qi "raspberry pi" /proc/cpuinfo 2>/dev/null; then
    printf 'pi'
    return 0
  fi

  printf 'debian'
}

SPOKE_KIND="$(detect_spoke_kind)"

case "${SPOKE_KIND}" in
  pi)
    SOURCE_DIR="SPOKE"
    DEPLOY_SCRIPT="deploy-spoke.sh"
    ;;
  debian)
    SOURCE_DIR="SPOKE-Debian"
    DEPLOY_SCRIPT="deploy-spoke-debian.sh"
    ;;
  *)
    echo "Unknown CONSOLEPI_SPOKE_KIND: ${SPOKE_KIND} (expected pi or debian)" >&2
    exit 1
    ;;
esac

TARGET_DIR="${INSTALL_ROOT}/${SOURCE_DIR}"
HUB_KEY_TARGET="${TARGET_DIR}/${HUB_KEY_FILE_NAME}"

echo "Detected spoke type: ${SPOKE_KIND} (using ${SOURCE_DIR})"

download_raw_file() {
  local repo_path="$1"
  local output_path="$2"
  local raw_url="${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_REF}/${repo_path}"

  mkdir -p "$(dirname "${output_path}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${raw_url}" -o "${output_path}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "${raw_url}" -O "${output_path}"
  else
    echo "Need curl or wget to download ${repo_path}." >&2
    exit 1
  fi
}

download_raw_file_optional() {
  local repo_path="$1"
  local output_path="$2"
  local raw_url="${REPO_URL/github.com/raw.githubusercontent.com}/${REPO_REF}/${repo_path}"

  mkdir -p "$(dirname "${output_path}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${raw_url}" -o "${output_path}" || return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -q "${raw_url}" -O "${output_path}" || return 0
  fi
}

bootstrap_spoke_tree_without_git() {
  mkdir -p "${TARGET_DIR}/profiles" "${TARGET_DIR}/rendered"

  download_raw_file "${SOURCE_DIR}/${DEPLOY_SCRIPT}" "${TARGET_DIR}/${DEPLOY_SCRIPT}"
  download_raw_file "${SOURCE_DIR}/.env.example" "${TARGET_DIR}/.env.example"
  download_raw_file "${SOURCE_DIR}/README.md" "${TARGET_DIR}/README.md"

  if [[ "${SPOKE_KIND}" == "pi" ]]; then
    download_raw_file "${SOURCE_DIR}/PI_CONSOLEPI_SETUP.md" "${TARGET_DIR}/PI_CONSOLEPI_SETUP.md"
  fi

  download_raw_file_optional "HUB/consolepi/ssh/hub_spoke_ed25519.pub" "${HUB_KEY_TARGET}"

  chmod +x "${TARGET_DIR}/${DEPLOY_SCRIPT}"
}

bootstrap_or_update_repo() {
  if [[ -d "${INSTALL_ROOT}" && ! -d "${INSTALL_ROOT}/.git" ]]; then
    bootstrap_spoke_tree_without_git
    return
  fi

  if command -v git >/dev/null 2>&1; then
    if [[ -d "${INSTALL_ROOT}/.git" ]]; then
      git -C "${INSTALL_ROOT}" fetch --depth 1 origin "${REPO_REF}"
      git -C "${INSTALL_ROOT}" checkout "${REPO_REF}" 2>/dev/null || git -C "${INSTALL_ROOT}" checkout -b "${REPO_REF}" "origin/${REPO_REF}"
      git -C "${INSTALL_ROOT}" sparse-checkout init --cone >/dev/null 2>&1 || true
      git -C "${INSTALL_ROOT}" sparse-checkout set "${SOURCE_DIR}"
      git -C "${INSTALL_ROOT}" merge --ff-only "origin/${REPO_REF}"
    else
      git clone --depth 1 --filter=blob:none --sparse --branch "${REPO_REF}" "${REPO_URL}" "${INSTALL_ROOT}"
      git -C "${INSTALL_ROOT}" sparse-checkout set "${SOURCE_DIR}"
    fi

    download_raw_file_optional "HUB/consolepi/ssh/hub_spoke_ed25519.pub" "${HUB_KEY_TARGET}"
  else
    bootstrap_spoke_tree_without_git
  fi
}

main() {
  bootstrap_or_update_repo

  if [[ ! -x "${TARGET_DIR}/${DEPLOY_SCRIPT}" ]]; then
    chmod +x "${TARGET_DIR}/${DEPLOY_SCRIPT}"
  fi

  if [[ -z "${HUB_REMOTE_SSH_PUBKEY_FILE:-}" && -f "${HUB_KEY_TARGET}" ]]; then
    export HUB_REMOTE_SSH_PUBKEY_FILE="${HUB_KEY_TARGET}"
  fi

  cd "${TARGET_DIR}"
  exec "./${DEPLOY_SCRIPT}" "$@"
}

main "$@"

