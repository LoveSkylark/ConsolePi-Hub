# Raspberry Pi Spoke Setup (ConsolePi + WireGuard)

This guide provisions a spoke Pi as a ConsolePi node and attaches it to the HUB using a rendered `wg0.conf` from this folder.

The setup is mostly deterministic once the HUB profile, subnet, spoke slot, and hub
endpoint/public key are known. Everything else is derived or defaulted by the deploy script.

## 1) Base OS prep

1. On a laptop/workstation, use Raspberry Pi Imager to write Raspberry Pi OS Lite (64-bit, Bookworm) to the spoke Pi microSD/USB media.
1. In imager advanced options, set hostname, enable SSH, and configure credentials (or SSH key), locale, and timezone.
1. Boot the Pi from that media and log in.
1. Set hostname/timezone if needed:

```bash
sudo raspi-config
```

## 2) Preferred setup on the spoke

Run the deploy from this `SPOKE` folder on the Pi. If `.env` is missing or
required values are blank, the script prompts for the initial HUB connection details
and then writes `.env`.

```bash
chmod +x deploy-spoke.sh
./deploy-spoke.sh
```

The deploy script reads `.env` when present, installs WireGuard, renders `wg0.conf`, deploys it
to `/etc/wireguard/wg0.conf`, enables `wg-quick@wg0`, and optionally installs
ConsolePi in API-only mode.

On the first run, if `.env` is missing or values are blank, the script prompts for
the HUB profile, subnet, spoke slot, hub endpoint, and hub public key using defaults
where available. On later runs, it uses the existing `.env` values and just refreshes
the spoke config if you changed them.

ConsolePi install is enabled by default. Override for one deploy with
`INSTALL_CONSOLEPI=false ./deploy-spoke.sh` if needed.

During unattended ConsolePi install, the deploy script generates a transient
random password only to satisfy the upstream installer. It is not stored in `.env`.

After install, the `consolepi` account is hardened by locking its password and
setting a `nologin` shell when available.

The spoke public key is printed at the end of a full deploy so it can be copied to
the HUB.

The script generates the spoke private key on first full deploy.
Use `./deploy-spoke.sh --new-key` to rotate it later, and `./deploy-spoke.sh --get-key`
to print the current public key for the HUB peer entry.

## 3) Manual build of spoke WireGuard config from this repo

On your admin workstation in this `SPOKE` folder:

```bash
cp -n .env.example .env
# edit .env values
./deploy-spoke.sh --render-config
```

Output file:

- `rendered/wg0.conf`

## 4) Manual install of WireGuard config on the Pi

Copy rendered config to the Pi, then apply:

```bash
sudo apt install -y wireguard
sudo mkdir -p /etc/wireguard
sudo cp rendered/wg0.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

If copying from workstation directly, use scp first:

```bash
scp rendered/wg0.conf <pi-user>@<pi-ip>:/tmp/wg0.conf
ssh <pi-user>@<pi-ip> "sudo cp /tmp/wg0.conf /etc/wireguard/wg0.conf && sudo chmod 600 /etc/wireguard/wg0.conf && sudo systemctl enable --now wg-quick@wg0"
```

## 5) Verify on spoke and hub

On spoke:

```bash
sudo wg show
ip addr show wg0
```

On hub:

```bash
docker compose logs --tail=100 wireguard-hub
```

## 6) Profile behavior check

- This SPOKE pack renders one `wg0.conf` at a time.
- Set `HUB_PROFILE` to `trusted` or `untrusted` before rendering.
- Set `WG_SUBNET` to the matching HUB profile subnet (`10.99.99.0/24` trusted or `10.99.98.0/24` untrusted by default).
- Set `WG_SPOKE` to the HUB peer slot index for this spoke.
- HUB tunnel IP is auto-derived as host `.1`; spoke tunnel IP is auto-derived as host `.(10 + WG_SPOKE)`.
- Persistent keepalive defaults to `25`.
- ConsolePi silent-install country/locale defaults are derived from host locale when possible, with fallback to `US`.
- Override for one deploy with `COUNTRY=GB ./deploy-spoke.sh` if needed.
- Override keepalive for one deploy with `PERSISTENT_KEEPALIVE=15 ./deploy-spoke.sh` if needed.
- Trusted target: Pi can reach hub trusted WG IP and can access ConsolePi SSH path as designed.
- Untrusted target: Pi can establish VPN tunnel but is blocked from ConsolePi SSH by hub policy.

## 7) Recommended auth model

- Use SSH keys (no password auth) for access to ConsolePi on the hub.
- Keep private keys out of git.
- Rotate spoke keys if a device is repurposed or decommissioned.
