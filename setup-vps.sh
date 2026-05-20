#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo $0)"
  exit 1
fi

# ─── Load config ────────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.template to .env and fill in values."
  exit 1
fi
set -a; source .env; set +a

: "${WEBHOOK_SECRET:?Set WEBHOOK_SECRET in .env}"
: "${BASE_DOMAIN:?Set BASE_DOMAIN in .env}"
: "${ACME_EMAIL:?Set ACME_EMAIL in .env}"

USE_SSH_CLONE="${USE_SSH_CLONE:-true}"
SPIKE_DIR="$SCRIPT_DIR/spike-service"
SSH_KEY_FILE="${HOME}/.ssh/id_ed25519"

echo "==> PR Preview Spike — VPS Setup"
echo "    Domain:   ${BASE_DOMAIN}"
echo "    ACME:     ${ACME_EMAIL}"
echo "    Spike dir: ${SPIKE_DIR}"

# ─── 0. Generate SSH key for GitHub cloning ──────────────────────
if [ "${USE_SSH_CLONE}" = "true" ]; then
  echo "==> Step 0: SSH key for GitHub"
  if [ ! -f "${SSH_KEY_FILE}" ]; then
    mkdir -p "$(dirname "${SSH_KEY_FILE}")"
    ssh-keygen -t ed25519 -C "pr-preview-spike@VPS" -f "${SSH_KEY_FILE}" -N ""
    echo "  Generated: ${SSH_KEY_FILE}"
  fi
  echo "  Public key:"
  echo ""
  cat "${SSH_KEY_FILE}.pub"
  echo ""
  echo "  ⬆️  Add this key to GitHub:"
  echo "     Repo → Settings → Deploy keys → Add deploy key (tick 'Allow write access')"
  echo "     OR  → https://github.com/settings/keys  (add to your account)"
  echo ""
fi

# ─── 1. Install Docker + Compose ─────────────────────────────────
echo "==> Step 1: Installing Docker + Compose"
if ! command -v docker &>/dev/null; then
  echo "  Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2
  systemctl enable --now docker
fi
echo "  Docker:    $(docker --version 2>/dev/null || echo 'NOT FOUND')"
echo "  Compose:   $(docker compose version 2>/dev/null || echo 'NOT FOUND')"

# ─── 2. Install Node.js 20 ───────────────────────────────────────
echo "==> Step 2: Installing Node.js 20"
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi
echo "  Node:      $(node --version 2>/dev/null || echo 'NOT FOUND')"
echo "  npm:       $(npm --version 2>/dev/null || echo 'NOT FOUND')"

# ─── 3. Set up Traefik ───────────────────────────────────────────
echo "==> Step 3: Setting up Traefik"
docker network inspect traefik &>/dev/null || docker network create traefik

mkdir -p /opt/traefik/dynamic

# Create acme.json for Let's Encrypt
touch /opt/traefik/acme.json && chmod 600 /opt/traefik/acme.json

# Write Traefik compose file
cat > /opt/traefik/docker-compose.yml <<COMPOSE
services:
  traefik:
    image: traefik:v2.11
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./acme.json:/acme.json
      - ./dynamic:/etc/traefik/dynamic:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/acme.json"
    networks:
      - traefik

networks:
  traefik:
    external: true
COMPOSE

# Write Traefik dynamic config for webhook routing
cat > /opt/traefik/dynamic/webhooks.yml <<DYNAMIC
http:
  routers:
    webhook:
      rule: "Host(\`${BASE_DOMAIN}\`)"
      service: spike-webhook
      entryPoints: ["websecure"]
      tls:
        certResolver: letsencrypt
      priority: 100
  services:
    spike-webhook:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:3002"
DYNAMIC

# Restart Traefik if already running, otherwise start
if docker ps --format '{{.Names}}' | grep -q 'traefik'; then
  echo "  Tearing down existing Traefik..."
  docker compose -f /opt/traefik/docker-compose.yml -p traefik down
fi
docker compose -f /opt/traefik/docker-compose.yml -p traefik up -d
echo "  Traefik is running"

# ─── 4. Install spike service deps ───────────────────────────────
echo "==> Step 4: Installing spike service dependencies"
cd "$SPIKE_DIR"
npm install

# Write .env for spike service
cat > "$SPIKE_DIR/.env" <<ENVFILE
WEBHOOK_SECRET=${WEBHOOK_SECRET}
BASE_DOMAIN=${BASE_DOMAIN}
PORT=3002
USE_SSH_CLONE=${USE_SSH_CLONE}
ENVFILE

# ─── 5. Create systemd service ───────────────────────────────────
echo "==> Step 5: Creating systemd service"

cat > /etc/systemd/system/pr-preview-spike.service <<UNIT
[Unit]
Description=PR Preview Spike Service
After=network.target docker.service
Wants=network.target docker.service

[Service]
Type=simple
WorkingDirectory=${SPIKE_DIR}
ExecStart=/usr/bin/npx ts-node spike.ts
EnvironmentFile=${SPIKE_DIR}/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pr-preview-spike.service
systemctl restart pr-preview-spike.service

# Remove old smee service if it exists
if [ -f /etc/systemd/system/pr-preview-smee.service ]; then
  systemctl stop pr-preview-smee.service 2>/dev/null || true
  systemctl disable pr-preview-smee.service 2>/dev/null || true
  rm -f /etc/systemd/system/pr-preview-smee.service
  systemctl daemon-reload
fi

# ─── 6. Verify ───────────────────────────────────────────────────
echo ""
echo "==> Waiting 3s for services to start..."
sleep 3

echo "Systemd status:"
systemctl status pr-preview-spike.service --no-pager --lines=5 || true

echo ""
echo "==================================================================="
echo "  Setup complete!"
echo ""
echo "  Spike logs:  journalctl -u pr-preview-spike -f"
echo ""
echo "  Webhook URL (use in GitHub App): https://${BASE_DOMAIN}/webhooks"
echo "  App preview: http://pr-N.${BASE_DOMAIN}"
echo ""
echo "  Next:"
echo "  1. Create sample app repo (push sample-app/ to GitHub)"
echo "  2. Create GitHub App with webhook URL above"
echo "  3. Run test flows"
echo "==================================================================="
