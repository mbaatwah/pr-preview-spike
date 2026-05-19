# PR Preview Spike — Setup Instructions

Two setup methods are available. Pick one.

| Option | Script | When to use |
|--------|--------|-------------|
| **VPS-local** | `setup-vps.sh` | You're already SSH'd into the VPS and want to clone the repo there |
| **SSH-remote** | `provision.sh` | You want to provision the VPS from your local machine via SSH |

Both methods configure Traefik with Let's Encrypt for HTTPS webhook delivery — no smee proxy needed.

Follow the corresponding guide:

- **[SETUP-VPS.md](./SETUP-VPS.md)** — clone repo on VPS, run script locally
- **[SETUP-SSH.md](./SETUP-SSH.md)** — run script from your machine, SSH does the rest
