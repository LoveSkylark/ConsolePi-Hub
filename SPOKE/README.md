# ConnectPi SPOKE Config Pack

This folder builds one spoke `wg0.conf` that targets either HUB trusted or HUB untrusted.

For end-to-end Pi provisioning (ConsolePi install + WireGuard attach), see [PI_CONSOLEPI_SETUP.md](PI_CONSOLEPI_SETUP.md).

## Quick start on the spoke box

Run the interactive installer from this folder:

```bash
chmod +x install-spoke.sh
./install-spoke.sh
```

The installer will:

- ask for the hub endpoint, profile target, tunnel IPs, and hub public key
- generate or accept the spoke private key
- write `.env`
- render `rendered/wg0.conf`
- install WireGuard and enable `wg-quick@wg0`
- optionally install ConsolePi and disable mDNS discovery services

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
