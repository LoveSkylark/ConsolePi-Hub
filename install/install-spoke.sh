#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${CONSOLEPI_HUB_REPO_URL:-https://github.com/LoveSkylark/ConsolePi-Hub}"
REPO_REF="${CONSOLEPI_HUB_REPO_REF:-main}"
INSTALL_ROOT="${CONSOLEPI_SPOKE_ROOT:-${HOME}/ConnectPi-Spoke}"
TARGET_DIR="${INSTALL_ROOT}/SPOKE"
HUB_KEY_FILE_NAME="hub_spoke_ed25519.pub"
HUB_KEY_TARGET="${TARGET_DIR}/${HUB_KEY_FILE_NAME}"

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

  download_raw_file "SPOKE/deploy-spoke.sh" "${TARGET_DIR}/deploy-spoke.sh"
  download_raw_file "SPOKE/.env.example" "${TARGET_DIR}/.env.example"
  download_raw_file "SPOKE/README.md" "${TARGET_DIR}/README.md"
  download_raw_file "SPOKE/PI_CONSOLEPI_SETUP.md" "${TARGET_DIR}/PI_CONSOLEPI_SETUP.md"
  download_raw_file_optional "HUB/consolepi/ssh/hub_spoke_ed25519.pub" "${HUB_KEY_TARGET}"

  chmod +x "${TARGET_DIR}/deploy-spoke.sh"
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
      git -C "${INSTALL_ROOT}" sparse-checkout set SPOKE
      git -C "${INSTALL_ROOT}" merge --ff-only "origin/${REPO_REF}"
    else
      git clone --depth 1 --filter=blob:none --sparse --branch "${REPO_REF}" "${REPO_URL}" "${INSTALL_ROOT}"
      git -C "${INSTALL_ROOT}" sparse-checkout set SPOKE
    fi

    download_raw_file_optional "HUB/consolepi/ssh/hub_spoke_ed25519.pub" "${HUB_KEY_TARGET}"
  else
    bootstrap_spoke_tree_without_git
  fi
}

main() {
  bootstrap_or_update_repo

  if [[ ! -x "${TARGET_DIR}/deploy-spoke.sh" ]]; then
    chmod +x "${TARGET_DIR}/deploy-spoke.sh"
  fi

  if [[ -z "${HUB_REMOTE_SSH_PUBKEY_FILE:-}" && -f "${HUB_KEY_TARGET}" ]]; then
    export HUB_REMOTE_SSH_PUBKEY_FILE="${HUB_KEY_TARGET}"
  fi

  cd "${TARGET_DIR}"
  exec ./deploy-spoke.sh "$@"
}

main "$@"
