# ConsolePi Hub-and-Spoke Build Sheet — WireGuard behind FortiGate

**Goal:** A central hub VM (VMware) reaches every remote ConsolePi (Pi) over WireGuard. No remote can reach any other remote. Hub sits behind a FortiGate.

> **Key fact:** FortiGate has no native WireGuard (as of early 2026). WireGuard runs on the hub VM; the FortiGate only port-forwards UDP 51820 inbound and protects the VM. Spoke-to-spoke isolation is enforced **on the hub VM**, not on the FortiGate (the tunnel is opaque encrypted UDP to the firewall).

---

## Host VM specs

The hub is remote-only (no local serial adapters passed through), so its footprint is tiny — ConsolePi runs fine on a Pi 3, and WireGuard for a handful of spokes adds almost nothing.

| Resource | Minimum | Recommended |
|---|---|---|
| vCPU | 1 | 2 |
| RAM | 1 GB | 2 GB |
| Disk | 12 GB | 20–25 GB |
| vNIC | 1 × VMXNET3 | 1 × VMXNET3, static IP on FortiGate LAN |
| OS | 64-bit Debian 12 or Ubuntu 22.04/24.04 LTS | same |

- Pick a current LTS so WireGuard is **in-kernel** (Debian 11+/Ubuntu 20.04+, kernel 5.6+) — `apt install wireguard` then gives you just the tools, no DKMS module to compile.
- Install `open-vm-tools`, use VMXNET3, and snapshot before each config change.
- No USB passthrough, GPU, or other special hardware — traffic is SSH text sessions plus small reachability checks.

---

## 1. Addressing plan (adjust to taste)

| Element | Value |
|---|---|
| WireGuard subnet | `10.99.99.0/24` |
| Hub `wg0` | `10.99.99.1` |
| Spoke 1 (`wg0`) | `10.99.99.11` |
| Spoke 2 (`wg0`) | `10.99.99.12` |
| Hub VM LAN IP (behind FortiGate) | `10.10.10.5` |
| FortiGate public/WAN IP | `<PUBLIC_IP>` |
| WireGuard port | UDP `51820` |

Trust direction: **hub initiates SSH outbound to spokes.** Spokes only ever bring up the tunnel and wait.

Before locking this in, verify `10.99.99.0/24` does **not** overlap with any remote-site LAN, transit VPN, or existing tunnel range.

---

## 2. FortiGate configuration

The FortiGate exposes the WireGuard port to the VM and nothing else. Do this once.

### 2a. Custom service (UDP 51820)
```
config firewall service custom
    edit "wg-udp-51820"
        set udp-portrange 51820
    next
end
```

### 2b. Virtual IP (DNAT) — external UDP 51820 → hub VM
```
config firewall vip
    edit "wg-hub"
        set extip <PUBLIC_IP>
        set extintf "wan1"
        set portforward enable
        set protocol udp
        set extport 51820
        set mappedip 10.10.10.5
        set mappedport 51820
    next
end
```

### 2c. Inbound policy (WAN → hub VM)
```
config firewall policy
    edit 0
        set name "wg-inbound"
        set srcintf "wan1"
        set dstintf "lan"
        set srcaddr "all"
        set dstaddr "wg-hub"
        set action accept
        set schedule "always"
        set service "wg-udp-51820"
        set logtraffic all
    next
end
```

### 2d. Do NOT let application control block WireGuard  ⚠️
FortiGuard app control identifies and blocks WireGuard by default. On the `wg-inbound` policy, either apply **no** application-control profile, or edit the profile so the **WireGuard** application signature is set to **Allow/Monitor** rather than Block. Verify after first connection that handshakes are completing.

> You do not need any inbound rule *from* the spokes beyond this — all spoke traffic rides inside the single UDP/51820 flow.

---

## 3. Hub VM — WireGuard server

On the VMware Linux VM (Ubuntu/Debian):

```bash
sudo apt update && sudo apt install -y wireguard
wg genkey | tee hub.key | wg pubkey > hub.pub     # hub keypair
# generate a keypair per spoke the same way, on each spoke (see §4)

# lock down private key material
chmod 600 hub.key
```

`/etc/wireguard/wg0.conf` on the hub:
```ini
[Interface]
Address = 10.99.99.1/24
ListenPort = 51820
PrivateKey = <HUB_PRIVATE_KEY>
# NOTE: no PostUp masquerade, no ip_forward — see §5

[Peer]
# Spoke 1
PublicKey = <SPOKE1_PUBLIC_KEY>
AllowedIPs = 10.99.99.11/32

[Peer]
# Spoke 2
PublicKey = <SPOKE2_PUBLIC_KEY>
AllowedIPs = 10.99.99.12/32
```

Each peer's `AllowedIPs` is a **/32** — the hub only ever routes to that one spoke address, never a wider range.

Bring it up:
```bash
sudo systemctl enable --now wg-quick@wg0
```

If your WAN/public IP can change, use a DDNS hostname for the spoke `Endpoint` target instead of a raw IP.

---

## 4. Spoke (each Pi) — WireGuard client

On each Pi (installed via the ConsolePi installer already), install WireGuard and generate a keypair:
```bash
sudo apt install -y wireguard
wg genkey | tee spoke.key | wg pubkey > spoke.pub
chmod 600 spoke.key
```

`/etc/wireguard/wg0.conf` on **Spoke 1** (repeat with `.11`→`.12` etc. for others):
```ini
[Interface]
Address = 10.99.99.11/32
PrivateKey = <SPOKE1_PRIVATE_KEY>

[Peer]
# The hub ONLY
PublicKey = <HUB_PUBLIC_KEY>
Endpoint = <PUBLIC_IP>:51820
AllowedIPs = 10.99.99.1/32
PersistentKeepalive = 25
```

Two critical lines:
- **`AllowedIPs = 10.99.99.1/32`** — the spoke has a route to the hub and to *nothing else*. It cannot address a sibling spoke even if it wanted to.
- **`PersistentKeepalive = 25`** — required. The spoke is behind NAT at the remote site; keepalive holds the NAT mapping open so the **hub can initiate** the SSH session inbound. Without it, the hub can't reach the spoke until the spoke speaks first.

Enable:
```bash
sudo systemctl enable --now wg-quick@wg0
```

> You can pre-stage this file (and the keys) via the ConsolePi Image Creator's `consolepi-stage` dir so new Pis come up already dialing home.

---

## 5. Isolation enforcement on the hub  ⭐ (the important part)

This is what guarantees spoke-to-spoke is impossible. Two layers:

**Layer 1 — Keep IP forwarding OFF.** Reaching another spoke requires the hub to *forward* a packet from one `wg0` peer to another. If forwarding is disabled, that can't happen. Hub→spoke still works because that traffic *originates* on the hub.
```bash
# confirm it is 0 (default). Make sure nothing else re-enables it:
sysctl net.ipv4.ip_forward        # expect: net.ipv4.ip_forward = 0
```
If some other role on the VM needs forwarding globally, add Layer 2.

**Layer 2 — Explicit drop of wg0→wg0 (belt and suspenders).** Harmless even with forwarding off:
```bash
sudo iptables -A FORWARD -i wg0 -o wg0 -j DROP
# persist it (e.g. netfilter-persistent / iptables-persistent), or add as PostUp in wg0.conf:
#   PostUp = iptables -A FORWARD -i wg0 -o wg0 -j DROP
#   PostDown = iptables -D FORWARD -i wg0 -o wg0 -j DROP
```

**Layer 3 (already done in §4)** — Each spoke's `AllowedIPs` lists only the hub, so a spoke has no route to a sibling to begin with.

Result: **hub → every spoke = yes; spoke → any other spoke = no**, enforced three independent ways.

### 5a. Persist the isolation rule on modern Debian/Ubuntu
Debian 12/Ubuntu 22.04+ commonly use the nftables backend. Pick one persistence path and standardize it:

- `iptables-persistent`/`netfilter-persistent` (simplest when following the iptables examples above), or
- native `nftables` ruleset with an equivalent forward drop for `iif wg0 oif wg0`.

Whichever you choose, reboot once and verify the drop rule is still present.

### 5b. Hub host firewall baseline
FortiGate is the perimeter control, but keep a minimal host firewall on the VM too:

- allow UDP `51820` inbound to the hub,
- allow administrative SSH only from trusted management source(s),
- default-drop unsolicited inbound.

---

## 6. ConsolePi — install & configure

### 6a. Install ConsolePi on the hub VM (non-Pi method)
The one-line installer is Pi-only. On the VM, install manually — it clones the repo into `/etc`, builds a virtualenv, and puts the `consolepi-*` commands on your PATH:

```bash
# prerequisites
sudo apt update
sudo apt install -y git python3-pip virtualenv

# clone and stage into /etc
cd /tmp
git clone https://github.com/Pack3tL0ss/ConsolePi.git
cd ConsolePi
python3 -m virtualenv venv
sudo mv /tmp/ConsolePi /etc

# add consolepi commands to PATH (loads on each login thereafter)
sudo cp /etc/ConsolePi/src/consolepi.sh /etc/profile.d
. /etc/profile.d/consolepi.sh

# install python requirements + fix perms
consolepi-sync -pip

# create the working config from the example, then edit it
sudo cp /etc/ConsolePi/ConsolePi.yaml.example /etc/ConsolePi/ConsolePi.yaml
consolepi-config
```

In `consolepi-config`, apply the hub settings from §6b below, then launch the menu:
```bash
consolepi-menu
```

> **For this isolated hub-and-spoke design, do NOT enable the mDNS services** (`consolepi-mdnsreg` / `consolepi-mdnsbrowse`). The generic laptop walkthrough enables `mdnsbrowse` to auto-discover peers on a shared LAN — you don't want that here. The hub learns its spokes from the manual `HOSTS:` entries, read straight from `ConsolePi.yaml` at menu launch, so no ConsolePi daemon needs to run at all.
>
> **Updates:** on a non-Pi host use `consolepi-sync` (or `git pull` inside `/etc/ConsolePi`) — **not** `consolepi-upgrade`, which assumes Pi hardware.

### 6b. Hub VM config — the only node that knows the topology
- In `OVERRIDES:` set `cloud_pull_only: true` (never advertises itself).
- **Do NOT** enable Google Drive cloud sync (its shared CSV would leak every spoke's address).
- Put each spoke in `HOSTS:`, pointed at its WireGuard IP:

```yaml
HOSTS:
  site-a-sw:
    address: 10.99.99.11
    method: ssh
    username: consolepi
    group: SITE-A
    show_in_main: true
  site-b-sw:
    address: 10.99.99.12
    method: ssh
    username: consolepi
    group: SITE-B
    show_in_main: true
```

The hub's `consolepi-menu` becomes your single launch point into every site.

### 6c. Each spoke Pi — a dumb console server, no topology knowledge
> Spokes use the normal Pi one-line installer (§ ConsolePi TL;DR); only the hub needs the manual install above.
- **Disable discovery** so it never learns about or advertises to peers:
```bash
sudo systemctl disable --now consolepi-mdnsreg consolepi-mdnsbrowse
```
- Leave `HOSTS:` empty and `/etc/ConsolePi/cloud.json` empty/absent.
- **Do NOT** enable Google Drive sync.
- Keep the unauthenticated ConsolePi REST API (TCP 5000, HTTP) bound only to the tunnel — never a public interface. In this design only the hub can reach it anyway.

---

## 7. Bring-up order

1. FortiGate: service, VIP, policy, confirm app-control isn't blocking WireGuard (§2).
2. Hub VM: install WireGuard, write `wg0.conf`, `wg-quick@wg0` up (§3).
3. Confirm `ip_forward = 0` and add the wg0→wg0 drop (§5).
4. First spoke: install WireGuard, write `wg0.conf`, `wg-quick@wg0` up (§4).
5. On the hub: `sudo wg show` — confirm a handshake and a recent `latest handshake` for the spoke.
6. From the hub: `ssh consolepi@10.99.99.11` — confirm reachability.
7. Add each remaining spoke, then add them to the hub's `HOSTS:` and launch `consolepi-menu`.

---

## 8. Hardening, reliability, and runbook notes

### 9a. SSH hardening for hub → spoke
- Use SSH keys for the `consolepi` account (no password auth if operationally possible).
- Keep host-key checking enabled; pre-populate or verify `known_hosts` so automation is not vulnerable to MITM prompts.
- Restrict SSH exposure to tunnel paths where possible.

### 9b. Time and DNS sanity
- Ensure NTP is healthy on hub and all spokes (`timedatectl` should show synchronized).
- If using DDNS for the hub endpoint, verify remote resolvers can resolve it reliably.

### 9c. MTU fallback (only if symptoms appear)
If handshakes work but larger SSH/output sessions stall or flap, test a lower MTU on hub and spokes:

```ini
[Interface]
MTU = 1380
```

Apply on both sides of the affected tunnel and retest.

### 9d. Quick troubleshooting sequence
If a spoke is down or unreachable from hub:

1. On hub and spoke: `sudo wg show` (is there a recent handshake? transfer counters moving?)
2. On each side: `sudo systemctl status wg-quick@wg0` and `sudo journalctl -u wg-quick@wg0 --since -15m`
3. Verify spoke config still has `AllowedIPs = 10.99.99.1/32` and keepalive `25`.
4. Verify hub still has `net.ipv4.ip_forward = 0` and wg0→wg0 drop rule loaded.
5. On FortiGate: check policy hit counts/logs and app-control behavior for WireGuard.

### 9e. Key rotation mini-runbook (per spoke)
1. Generate a new spoke keypair on the spoke.
2. Replace that spoke's `PublicKey` on the hub peer entry.
3. Replace the spoke `PrivateKey` locally.
4. Restart both ends (`wg-quick@wg0`) during a short maintenance window.
5. Confirm handshake + SSH from hub before closing the change.

---

## 9. Prove the isolation (do this before trusting it)

**Hub can reach a spoke:**
```bash
# on the hub
ping -c2 10.99.99.11        # spoke 1  -> should succeed
ping -c2 10.99.99.12        # spoke 2  -> should succeed
```

**A spoke CANNOT reach its sibling:**
```bash
# on spoke 1 (10.99.99.11)
ping -c2 10.99.99.12        # -> MUST fail (no route: sibling not in AllowedIPs)
ip route get 10.99.99.12    # -> should show no wg0 route to the sibling
```

**A spoke can reach only the hub:**
```bash
# on spoke 1
ping -c2 10.99.99.1         # -> should succeed (hub)
```

If the sibling ping ever succeeds, stop and recheck: spoke `AllowedIPs` (must be hub /32 only), hub `ip_forward` (must be 0), and the wg0→wg0 DROP rule.

---

## Quick reference — what lives where

| | Hub VM (VMware) | Spoke Pi |
|---|---|---|
| WireGuard | server, all peers | client, hub-only peer |
| Knows the topology | yes (`HOSTS:`) | no |
| Discovery (mDNS/gdrive) | off | off |
| Initiates connections | yes (SSH out to spokes) | no (tunnel only) |
| ConsolePi role | central menu hub | console server |
| Isolation control | `ip_forward=0` + wg0→wg0 DROP | `AllowedIPs = hub/32` |