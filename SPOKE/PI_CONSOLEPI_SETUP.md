# Raspberry Pi Spoke Setup (ConsolePi + WireGuard)

This guide provisions a spoke Pi as a ConsolePi node and attaches it to the HUB using a rendered `wg0.conf` from this folder.

## 1) Base OS prep

1. On a laptop/workstation, use Raspberry Pi Imager to write Raspberry Pi OS Lite (64-bit, Bookworm) to the spoke Pi microSD/USB media.
1. In imager advanced options, set hostname, enable SSH, and configure credentials (or SSH key), locale, and timezone.
1. Boot the Pi from that media and log in.
1. Update packages:

```bash
sudo apt update && sudo apt upgrade -y
```

1. Set hostname/timezone if needed:

```bash
sudo raspi-config
```

## 2) Install ConsolePi on the Pi

Use the upstream installer on an internet-connected Pi:

```bash
wget -q https://raw.githubusercontent.com/Pack3tL0ss/ConsolePi/master/installer/install.sh -O /tmp/ConsolePi
sudo bash /tmp/ConsolePi
sudo rm -f /tmp/ConsolePi
```

## 3) Spoke hardening for hub-and-spoke model

This section is optional for your current policy. Your primary requirement
(no spoke-to-spoke communication over VPN, hub-only over VPN) is enforced by
WireGuard routing and hub-side FORWARD drop rules.

Disable discovery/advertising services so spokes do not build peer topology:

```bash
sudo systemctl disable --now consolepi-mdnsreg consolepi-mdnsbrowse
```

In ConsolePi config on the spoke:

- Keep `HOSTS:` empty.
- Do not enable Google Drive/cloud sync.
- Keep spoke role limited to local console access plus hub-initiated SSH.

## 4) Preferred setup on the spoke

Run the interactive installer from this `SPOKE` folder on the Pi:

```bash
chmod +x install-spoke.sh
./install-spoke.sh
```

The installer will prompt for the values needed to build `.env`, install WireGuard,
render `wg0.conf`, deploy it to `/etc/wireguard/wg0.conf`, enable `wg-quick@wg0`,
and optionally install ConsolePi.

It also prints the spoke public key at the end so you can confirm the matching HUB peer entry.

## 5) Manual build of spoke WireGuard config from this repo

On your admin workstation in this `SPOKE` folder:

```bash
cp -n .env.example .env
# edit .env values
./render-spoke-config.sh
```

Output file:

- `rendered/wg0.conf`

## 6) Manual install of WireGuard config on the Pi

Copy rendered config to the Pi, then apply:

```bash
sudo apt install -y wireguard
sudo mkdir -p /etc/wireguard
sudo cp wg0.conf /etc/wireguard/wg0.conf
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

If copying from workstation directly, use scp first:

```bash
scp rendered/wg0.conf <pi-user>@<pi-ip>:/tmp/wg0.conf
ssh <pi-user>@<pi-ip> "sudo cp /tmp/wg0.conf /etc/wireguard/wg0.conf && sudo chmod 600 /etc/wireguard/wg0.conf && sudo systemctl enable --now wg-quick@wg0"
```

## 7) Verify on spoke and hub

On spoke:

```bash
sudo wg show
ip addr show wg0
```

On hub:

```bash
docker compose logs --tail=100 wireguard-trusted
docker compose logs --tail=100 wireguard-untrusted
```

## 8) Profile behavior check

- This SPOKE pack renders one `wg0.conf` at a time.
- Set `.env` to trusted values (port 51821, `10.99.99.x`) or untrusted values (port 51820, `10.99.98.x`) before rendering.
- Trusted target: Pi can reach hub trusted WG IP and can access ConsolePi SSH path as designed.
- Untrusted target: Pi can establish VPN tunnel but is blocked from ConsolePi SSH by hub policy.

## 9) Recommended auth model

- Use SSH keys (no password auth) for access to ConsolePi on the hub.
- Keep private keys out of git.
- Rotate spoke keys if a device is repurposed or decommissioned.
