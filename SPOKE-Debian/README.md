# ConnectPi SPOKE (Debian Laptop / Generic Debian Host)

This folder deploys a WireGuard + ConsolePi spoke on a fresh Debian (or
Debian-based) machine — for example a laptop — instead of a Raspberry Pi.

Unlike `SPOKE/`, which uses the ConsolePi one-line installer designed for
Raspberry Pi OS, this folder:

- runs `apt-get update && apt-get upgrade` and installs all required packages
- installs ConsolePi manually via `git clone` + Python `venv`, the same method
  ConsolePi documents for non-Pi Linux hosts and the same method this repo's
  HUB container uses
- deploys the same WireGuard spoke tunnel model as `SPOKE/` (trusted/untrusted
  profile, `/32` peer addressing, shared HUB->SPOKE SSH key)

See the main [README.md](../README.md) for the overall HUB/SPOKE design and
[HUB/README.md](../HUB/README.md#how-the-hub-and-spoke-connect) for the
connection model diagram.

## What gets installed

- `wireguard`, `wireguard-tools`
- `git`, `python3`, `python3-venv`, `python3-pip`, `python3-dev`
- `build-essential`, `libffi-dev`, `libssl-dev`
- `openssh-client`, `openssh-server` (HUB connects to this spoke over SSH)
- `sudo`, `curl`, `ca-certificates`
- `iproute2`, `net-tools`, `iputils-ping`

ConsolePi is cloned to `/etc/ConsolePi` with its own virtualenv at
`/etc/ConsolePi/venv`, matching the upstream non-Pi install method.

## 1) Prepare

1. Copy `.env.example` to `.env` and adjust `HUB_PROFILE`, `WG_SUBNET`, and
   `WG_SPOKE` for this spoke. Leave `HUB_PUBLIC_KEY` as-is if you will be
   prompted for it, or set it directly.
2. Ensure `hub_spoke_ed25519.pub` in this folder resolves to the same shared
   HUB->SPOKE public key used elsewhere in this repo. By default it is a
   symlink to `../HUB/consolepi/ssh/hub_spoke_ed25519.pub`.

## 2) Run the installer

```bash
chmod +x deploy-spoke-debian.sh
sudo ./deploy-spoke-debian.sh
```

On first run, if values are missing from `.env`, the script prompts for:
`HUB_PROFILE`, `WG_SUBNET`, `WG_SPOKE`, `HUB_ENDPOINT`, and `HUB_PUBLIC_KEY`.

The script will:

- update apt and install all required packages
- generate a spoke WireGuard keypair on first run (stored under `rendered/`)
- render and deploy `/etc/wireguard/wg0.conf`, enable `wg-quick@wg0`
- clone/update ConsolePi at `/etc/ConsolePi` and set up its virtualenv
  (unless `--no-consolepi` is passed)
- set ConsolePi to `cloud_pull_only: true` (never advertises this spoke)
- enable the `consolepi-api` systemd service if the unit file is present in
  the cloned repo, so the HUB can reach ConsolePi's API over the tunnel
- install the shared HUB->SPOKE SSH key for the `consolepi` account so the
  HUB can SSH in without a password

At the end it prints the spoke public key; register it on the HUB with
[`HUB/wireguard/register-peer.sh`](../HUB/wireguard/register-peer.sh) using
the same profile and slot.

## Options

```bash
./deploy-spoke-debian.sh --new-key        # rotate the spoke private key
./deploy-spoke-debian.sh --get-key        # print current spoke public key
./deploy-spoke-debian.sh --render-config  # render wg0.conf from .env only
./deploy-spoke-debian.sh --status         # print tunnel/API status and exit
./deploy-spoke-debian.sh --skip-packages  # skip apt update/upgrade/install
./deploy-spoke-debian.sh --no-consolepi   # WireGuard tunnel only, skip ConsolePi
```

## Verify

```bash
sudo wg show
ip addr show wg0
curl -s http://127.0.0.1:5000/api/v1.0/details | head
```

## Notes and limitations

- `openssh-server` is required and enabled because the HUB initiates SSH to
  this spoke over the tunnel; without it HUB-to-SPOKE SSH will not work.
- ConsolePi features that assume Raspberry Pi hardware (AutoHotSpot,
  onboard GPIO UARTs) are not configured by this script. USB-to-serial
  adapters still work if physically attached and detected by the kernel.
- To update ConsolePi later, run `git -C /etc/ConsolePi pull` (or
  `consolepi-sync` if available after sourcing `/etc/profile.d/consolepi.sh`).
  Do not use `consolepi-upgrade`; it assumes the Raspberry Pi installer flow.
- Re-running this script is safe: it reuses the existing spoke key, updates
  packages, pulls the latest ConsolePi, and re-renders the WireGuard config.
