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
: "${SMEE_CHANNEL:?Set SMEE_CHANNEL in .env}"

SPIKE_DIR="$SCRIPT_DIR/spike-service"

echo "==> PR Preview Spike — VPS Setup"
echo "    Domain:   ${BASE_DOMAIN}"
echo "    Smee:     ${SMEE_CHANNEL}"
echo "    Spike dir: ${SPIKE_DIR}"

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

mkdir -p /opt/traefik
cat > /opt/traefik/docker-compose.yml <<'COMPOSE'
services:
  traefik:
    image: traefik:v3.3
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command:
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
    networks:
      - traefik

networks:
  traefik:
    external: true
COMPOSE

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
ENVFILE

# ─── 5. Install smee client ──────────────────────────────────────
echo "==> Step 5: Installing smee-client"
npm install --save-dev smee-client

# ─── 6. Create systemd services ──────────────────────────────────
echo "==> Step 6: Creating systemd services"

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

cat > /etc/systemd/system/pr-preview-smee.service <<UNIT
[Unit]
Description=Smee Webhook Proxy for PR Preview
After=network.target pr-preview-spike.service
Wants=network.target pr-preview-spike.service

[Service]
Type=simple
WorkingDirectory=${SPIKE_DIR}
ExecStart=/usr/bin/npx smee -u ${SMEE_CHANNEL} -t http://localhost:3002/webhooks
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable pr-preview-spike.service pr-preview-smee.service
systemctl restart pr-preview-spike.service pr-preview-smee.service

# ─── 7. Verify ───────────────────────────────────────────────────
echo ""
echo "==> Waiting 3s for services to start..."
sleep 3

echo "Systemd status:"
systemctl status pr-preview-spike.service --no-pager --lines=5 || true
echo "---"
systemctl status pr-preview-smee.service --no-pager --lines=5 || true

echo ""
echo "==================================================================="
echo "  Setup complete!"
echo ""
echo "  Spike logs:  journalctl -u pr-preview-spike -f"
echo "  Smee logs:   journalctl -u pr-preview-smee -f"
echo ""
echo "  Webhook URL (use in GitHub App): ${SMEE_CHANNEL}"
echo ""
echo "  Next:"
echo "  1. Create sample app repo (push sample-app/ to GitHub)"
echo "  2. Create GitHub App with webhook URL above"
echo "  3. Run test flows"
echo "==================================================================="
