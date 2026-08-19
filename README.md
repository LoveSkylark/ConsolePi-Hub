# ConnectPi WireGuard Hub/Spoke Pack

This tree is a staging pack for moving the ConnectPi hub-and-spoke WireGuard work into the LoveSkylark/ConsolePi-Hub repository.

## Contents

- `HUB/`: Docker-based hub stack with trusted and untrusted WireGuard profiles plus optional ConsolePi container.
- `SPOKE/`: spoke-side installer, renderer, and Raspberry Pi setup docs.
- `SPOKE-Debian/`: spoke-side installer for generic Debian-based hosts (e.g. a laptop), installing ConsolePi manually instead of via the Pi-only installer.

## Import intent

This package is structured so it can be copied into an existing repo without carrying local secrets or runtime state.

Files intended to stay out of git are ignored at the repo root:

- local `.env` files
- rendered spoke configs
- live WireGuard server configs
- generated WireGuard key files and client profile examples
- generated peer snippets
- runtime ConsolePi data and imported system-user keys
- local backup files

## Before publishing upstream

1. Keep `.env.example` files as the tracked templates.
2. Do not commit real WireGuard private keys or active `.conf` files.
3. Do not commit `HUB/consolepi/data/` runtime contents.
4. Review paths and naming so they fit the final layout inside LoveSkylark/ConsolePi-Hub.

## Primary entrypoints

- Hub setup: `HUB/README.md`
- Raspberry Pi spoke setup: `SPOKE/README.md`
- Debian spoke setup: `SPOKE-Debian/README.md`
- Spoke deploy tools: `SPOKE/deploy-spoke.sh`, `SPOKE-Debian/deploy-spoke-debian.sh`
- Hub peer helper: `HUB/wireguard/register-peer.sh`

## Direct SPOKE install

Run on the spoke host to install/update the SPOKE tooling and deploy. The installer
detects whether it's running on a Raspberry Pi or a generic Debian-based host and
runs the matching deploy script (`SPOKE/deploy-spoke.sh` or
`SPOKE-Debian/deploy-spoke-debian.sh`). Override detection with
`CONSOLEPI_SPOKE_KIND=pi` or `CONSOLEPI_SPOKE_KIND=debian` if needed.

```bash
curl -fsSL https://raw.githubusercontent.com/LoveSkylark/ConsolePi-Hub/main/install/install-spoke.sh | bash
```

