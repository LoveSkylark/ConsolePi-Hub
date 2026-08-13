# ConnectPi SPOKE Config Pack

This folder builds one spoke `wg0.conf` that targets either HUB trusted or HUB untrusted.

The deploy is intentionally low-input: after you choose the HUB profile and a few
connection values on first run, the rest of the config is derived and later reruns
simply re-render from `.env`.

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
6. Log in to the Pi and continue with the deploy steps below.

## Quick start on the spoke box

Run the deploy from this folder. If `.env` is missing or required values are blank,
the script prompts for the initial HUB connection details and then writes `.env`.

```bash
chmod +x deploy-spoke.sh
./deploy-spoke.sh
```

Optional key rotation mode:

```bash
./deploy-spoke.sh --new-key
```

`--new-key` forces a new spoke keypair and updates `.env`.

Print the current public key for HUB registration:

```bash
./deploy-spoke.sh --get-key
```

Optional preseed retention mode (for troubleshooting):

```bash
./deploy-spoke.sh --keep-preseed
```

`--keep-preseed` keeps the ConsolePi preseed file instead of deleting it after a successful install.

Status check mode (no changes applied):

```bash
./deploy-spoke.sh --status
```

`--status` prints live WireGuard (`wg show wg0`) and ConsolePi API status, then exits.

The deploy script will:

- read `.env` when present and prompt only for missing required values on first run
- generate the spoke private key on first full deploy if it is missing
- rotate the spoke private key only when `--new-key` is used
- write `.env` back with the generated connection values
- render `rendered/wg0.conf`
- install WireGuard and enable `wg-quick@wg0`
- optionally install ConsolePi in API-only mode (enables `consolepi-api`, disables mDNS services)
- store the spoke keypair files under `rendered/spoke.privatekey` and `rendered/spoke.publickey`

At the end it prints the spoke public key so you can register it on the HUB if needed.

## 1) Prepare

1. Optional: copy `.env.example` to `.env` if you want to preseed values before first deploy.
2. If values are missing, `deploy-spoke.sh` prompts for:
	`HUB_PROFILE`, `WG_SUBNET`, `WG_SPOKE`, `HUB_ENDPOINT`, and `HUB_PUBLIC_KEY`.
3. The script also prompts for HUB remote shell access values on first run:
	`HUB_REMOTE_SSH_USER` and `HUB_REMOTE_SSH_PUBKEY`.
4. Use the HUB-generated key from `HUB/consolepi/ssh/hub_spoke_ed25519.pub` as `HUB_REMOTE_SSH_PUBKEY`.
3. On second and later runs, it uses the values already in `.env` and only rebuilds the spoke config.

Derived values:

- trusted profile uses UDP port `51821`
- untrusted profile uses UDP port `51820`
- hub tunnel IP is always host `.1` in `WG_SUBNET`
- spoke tunnel IP is host `.(10 + WG_SPOKE)` in `WG_SUBNET`
- persistent keepalive defaults to `25`

ConsolePi install behavior:

- mDNS advertise/browse services are disabled after install
- `consolepi-api` is enabled for HUB access on the upstream default port `5000`
- ConsolePi country/locale defaults are derived from host locale when possible, with fallback to `US`
- ConsolePi install defaults to enabled; override per run with `INSTALL_CONSOLEPI=false ./deploy-spoke.sh`
- the deploy script always generates a transient random password for the upstream silent installer and does not write it to `.env`
- after install, the `consolepi` account is hardened by locking its password and setting a `nologin` shell when available
- the spoke public key is always printed at the end of a full deploy so you can register it on the HUB

To override the derived country for a deploy, set `COUNTRY` in the shell before running the script:

```bash
COUNTRY=GB ./deploy-spoke.sh
```

To override keepalive for a deploy, set `PERSISTENT_KEEPALIVE` in the shell before running the script:

```bash
PERSISTENT_KEEPALIVE=15 ./deploy-spoke.sh
```

## 2) Render

```bash
chmod +x deploy-spoke.sh
./deploy-spoke.sh --render-config
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
