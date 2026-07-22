# ConsolePi Image (Debian Bookworm)

This image uses `debian:12-slim` to match the same Linux family used by Raspberry Pi OS Bookworm.

## Build

```bash
docker compose build consolepi
```

## Start

```bash
docker compose --profile consolepi up -d consolepi
```

## Use

Open a shell in the container:

```bash
docker compose exec consolepi bash
```

Then run ConsolePi commands:

```bash
consolepi-menu
consolepi-config
consolepi-sync -h
```

## Persistence

- `/data/runtime/ConsolePi.yaml`: runtime ConsolePi config
- `/data/ssh`: optional SSH keys/known_hosts for hub to reach spokes

On first start, the container seeds `ConsolePi.yaml` from the upstream example.
