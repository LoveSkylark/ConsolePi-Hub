# ConnectPi HUB Docker Stack

This folder contains a Docker Compose based HUB baseline:

- WireGuard runs as two dedicated profile containers.
- Trusted WireGuard profile: can access ConsolePi.
- Untrusted WireGuard profile: blocked from ConsolePi SSH.
- ConsolePi is a local image build based on Debian 12 Bookworm.

## 1) Prepare files

One-command deploy helper (recommended):

```bash
chmod +x deploy-hub.sh
./deploy-hub.sh
```

Optional flags:

- `--without-consolepi`: skip starting the `consolepi` service
- `--refresh-configs`: recreates active `wg-*.conf` files from fresh rendered examples (with timestamped backups)

The script renders templates, ensures active config files exist, checks for placeholder keys, applies permissions, and starts WireGuard plus ConsolePi services.

Re-run behavior:

- safe to run repeatedly after editing `.env`
- preserves existing HUB private keys and existing peer public keys by matching `AllowedIPs`
- adds newly rendered peers from updated `WG_*_PEER_IPS` lists
- warns if new peers still have placeholder public keys
- if HUB private key placeholders are detected, prompts to generate missing keys automatically

1. Copy `.env.example` to `.env` and edit values.
1. Render profile templates from `.env`:

```bash
chmod +x wireguard/render-profile-configs.sh
./wireguard/render-profile-configs.sh
```

1. Copy templates to active configs and set keys:

```bash
cp wireguard/trusted/config/wg_confs/wg-trusted.conf.example wireguard/trusted/config/wg_confs/wg-trusted.conf
cp wireguard/untrusted/config/wg_confs/wg-untrusted.conf.example wireguard/untrusted/config/wg_confs/wg-untrusted.conf
```

1. Replace all key placeholders in both active `.conf` files.
1. Set strict key permissions on host:

```bash
chmod 700 wireguard/trusted/config wireguard/trusted/config/wg_confs
chmod 700 wireguard/untrusted/config wireguard/untrusted/config/wg_confs
chmod 600 wireguard/trusted/config/wg_confs/wg-trusted.conf
chmod 600 wireguard/untrusted/config/wg_confs/wg-untrusted.conf
```

To register a new spoke peer on the HUB after initial setup:

```bash
chmod +x wireguard/register-peer.sh
./wireguard/register-peer.sh
```

The helper will:

- ask for trusted or untrusted profile
- ask for peer label, peer tunnel IP, and peer public key
- update the matching peer IP list in `.env`
- rerender the example templates
- append the live peer stanza to the active hub config if it exists
- otherwise write a ready-to-paste snippet under `wireguard/profiles/`

## 2) Start WireGuard

```bash
docker compose up -d wireguard-trusted wireguard-untrusted
```

## 3) Verify

```bash
docker compose ps
docker compose logs --tail=100 wireguard-trusted
docker compose logs --tail=100 wireguard-untrusted
```

You should see interface startup and peer activity once spokes connect.

## 3a) Build and run ConsolePi container

Build the image:

```bash
docker compose build consolepi
```

Start the service:

```bash
docker compose up -d consolepi
```

Open an interactive shell and run ConsolePi commands:

```bash
docker compose exec consolepi bash
consolepi-menu
```

WireGuard peers can reach ConsolePi over the hub WireGuard IP using SSH:

- target: trusted profile hub IP on port `22` (for example `10.99.99.1:22`)
- username: `consolepi`
- authentication: key only

Place your admin public key in `./consolepi/data/ssh/authorized_keys` before starting the container.

SSH access is profile-restricted at interface level:

- trusted interface (`TRUSTED_SSH_INTERFACE`) is allowed
- untrusted interface (`UNTRUSTED_SSH_INTERFACE`) is denied

No per-IP allowlist management is required.

Dedicated external management SSH port is also exposed on the host:

- host port: `MGMT_SSH_PORT` (default `2222`)
- container target: `22`
- source restriction: `MGMT_SSH_ALLOW_CIDRS` (comma-separated CIDRs)

Set `MGMT_SSH_ALLOW_CIDRS` in `.env` to your management source(s), then connect:

```bash
ssh -p 2222 consolepi@<HUB_PUBLIC_IP_OR_DNS>
```

## 3b) Two WireGuard access profiles (A/B)

Use two client profile classes:

- Profile A (untrusted): VPN tunnel up, but blocked from ConsolePi SSH.
- Profile B (trusted): VPN tunnel up and permitted to access ConsolePi SSH.

Three example templates are provided for each class:

- `wireguard/profiles/profile-A1-untrusted.conf.example`
- `wireguard/profiles/profile-A2-untrusted.conf.example`
- `wireguard/profiles/profile-A3-untrusted.conf.example`
- `wireguard/profiles/profile-B1-trusted.conf.example`
- `wireguard/profiles/profile-B2-trusted.conf.example`
- `wireguard/profiles/profile-B3-trusted.conf.example`

Hub tunnel templates are also provided:

- `wireguard/trusted/config/wg_confs/wg-trusted.conf.example`
- `wireguard/untrusted/config/wg_confs/wg-untrusted.conf.example`

Network pools are driven by `.env` values:

- `WG_TRUSTED_SUBNET` (default `10.99.99.0/24`)
- `WG_UNTRUSTED_SUBNET` (default `10.99.98.0/24`)
- `WG_TRUSTED_PEER_IPS` (defaults to 3 sample peers)
- `WG_UNTRUSTED_PEER_IPS` (defaults to 3 sample peers)

The render script validates peer lists for empty entries, invalid IPv4 values, and duplicates.

You can also use the HUB registration helper non-interactively:

```bash
./wireguard/register-peer.sh \
  --profile trusted \
  --peer-name spoke-b4 \
  --peer-ip 10.99.99.14 \
  --public-key <SPOKE_PUBLIC_KEY>
```

## 4) FortiGate alignment

- Forward UDP 51820 (untrusted) and UDP 51821 (trusted) to this host.
- Forward TCP `MGMT_SSH_PORT` (default 2222) to this host for external ConsolePi management.
- Allow inbound policies for both UDP ports.
- Restrict inbound TCP `MGMT_SSH_PORT` policy to your management source addresses.
- Ensure app control does not block WireGuard.

## 5) Important runtime notes

- The `consolepi` service is included in normal compose lifecycle operations.
- It uses `network_mode: service:wireguard-trusted` so ConsolePi is attached to the trusted VPN namespace.
- Runtime data is persisted under `./consolepi/data`.
- Inbound SSH for ConsolePi is provided by the ConsolePi container itself and is reachable through the shared WireGuard namespace.
- Untrusted profile clients are blocked from SSH by interface policy applied at container startup.

## 6) Isolation model in this stack

- Each spoke peer should remain `/32` in `AllowedIPs`.
- Keep trusted and untrusted peers in separate profile subnets and containers.
- Keep any host-level forwarding changes in sync with this design.
