# ConnectPi SPOKE Config Pack

This folder builds one spoke `wg0.conf` that targets either HUB trusted or HUB untrusted.

For end-to-end Pi provisioning (ConsolePi install + WireGuard attach), see [PI_CONSOLEPI_SETUP.md](PI_CONSOLEPI_SETUP.md).

## Start from a fresh Raspberry Pi image

Deploy the base OS image on the spoke Pi itself (microSD or USB boot media), not on the hub host.

1. On your laptop/workstation, open Raspberry Pi Imager.
2. Choose OS: Raspberry Pi OS Lite (64-bit, Bookworm).
3. Choose storage: the microSD/USB that will live in the spoke Pi.
4. In advanced options before writing:
	- set hostname (example: `connectpi-spoke-01`)
	- enable SSH
	- set username/password or SSH public key
	- set locale/timezone/Wi-Fi if needed
5. Write image, insert media into the Pi, and boot it.
6. Log in to the Pi and run base updates:

```bash
sudo apt update && sudo apt upgrade -y
```

After that, continue with the sections below in this README.

## Quick start on the spoke box

Run the interactive installer from this folder:

```bash
chmod +x install-spoke.sh
./install-spoke.sh
```

Optional key rotation mode:

```bash
./install-spoke.sh --new-key
```

`--new-key` forces a new spoke keypair after an explicit warning prompt.

The installer will:

- ask for the hub endpoint, profile target, tunnel IPs, and hub public key
- generate or accept the spoke private key
- write `.env`
- render `rendered/wg0.conf`
- install WireGuard and enable `wg-quick@wg0`
- optionally install ConsolePi in API-only mode (enables `consolepi-api`, disables mDNS services)
- store the spoke keypair files under `rendered/spoke.privatekey` and `rendered/spoke.publickey`

At the end it prints the spoke public key so you can register it on the HUB if needed.

## 1) Prepare

1. Copy `.env.example` to `.env`.
2. Set `SPOKE_PROFILE` to `trusted` or `untrusted`.
3. Set `HUB_PORT`, `HUB_TUNNEL_IP`, and `SPOKE_TUNNEL_IP` for that selected profile target.
4. Ensure `SPOKE_TUNNEL_IP` matches an existing HUB peer entry in the selected hub profile config.
5. Fill in `SPOKE_PRIVATE_KEY` and `HUB_PUBLIC_KEY`.

## 2) Render

```bash
chmod +x render-spoke-config.sh
./render-spoke-config.sh
```

Rendered outputs:

- `rendered/wg0.conf`
- `rendered/summary.txt`

## 3) Apply on spoke host

```bash
sudo mkdir -p /etc/wireguard
sudo cp rendered/wg0.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

## 4) Verify

```bash
sudo wg show
ip addr show wg0
```

Expected behavior:

- `trusted` target: spoke can reach HUB and can SSH to ConsolePi over trusted profile.
- `untrusted` target: spoke can reach HUB tunnel endpoint but is blocked from ConsolePi SSH by HUB policy.
