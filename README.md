# ConnectPi WireGuard Hub/Spoke Pack

This tree is a staging pack for moving the ConnectPi hub-and-spoke WireGuard work into the LoveSkylark/ConsolePi-Hub repository.

## Contents

- `HUB/`: Docker-based hub stack with trusted and untrusted WireGuard profiles plus optional ConsolePi container.
- `SPOKE/`: spoke-side installer, renderer, and Raspberry Pi setup docs.
- `plan.md`: original design/build sheet used to shape the implementation.

## Import intent

This package is structured so it can be copied into an existing repo without carrying local secrets or runtime state.

Files intended to stay out of git are ignored at the repo root:

- local `.env` files
- rendered spoke configs
- live WireGuard server configs
- generated peer snippets
- runtime ConsolePi data
- local backup files

## Before publishing upstream

1. Keep `.env.example` files as the tracked templates.
2. Do not commit real WireGuard private keys or active `.conf` files.
3. Do not commit `HUB/consolepi/data/` runtime contents.
4. Review paths and naming so they fit the final layout inside LoveSkylark/ConsolePi-Hub.

## Primary entrypoints

- Hub setup: `HUB/README.md`
- Spoke setup: `SPOKE/README.md`
- Spoke deploy tool: `SPOKE/deploy-spoke.sh`
- Hub peer helper: `HUB/wireguard/register-peer.sh`

## Direct SPOKE install

Run on a Raspberry Pi to install/update the SPOKE tooling and deploy:

```bash
curl -fsSL https://raw.githubusercontent.com/LoveSkylark/ConsolePi-Hub/main/install/install-spoke.sh | bash
```

