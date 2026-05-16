#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Load config ────────────────────────────────────────────────
if [ ! -f .env ]; then
  echo "ERROR: .env file not found. Copy .env.template to .env and fill in values."
  exit 1
fi
source .env

: "${VPS_IP:?Set VPS_IP in .env}"
: "${VPS_USER:?Set VPS_USER in .env}"
: "${WEBHOOK_SECRET:?Set WEBHOOK_SECRET in .env}"
: "${BASE_DOMAIN:?Set BASE_DOMAIN in .env}"
: "${SMEE_CHANNEL:?Set SMEE_CHANNEL in .env}"

SSH="ssh"
if [ -n "${SSH_KEY_PATH:-}" ]; then
  SSH="ssh -i ${SSH_KEY_PATH}"
fi
SSH_TARGET="${VPS_USER}@${VPS_IP}"
SCP="scp"
if [ -n "${SSH_KEY_PATH:-}" ]; then
  SCP="scp -i ${SSH_KEY_PATH}"
fi

VPS_WORKDIR="/opt/pr-preview-spike"

echo "==> Provisioning VPS: ${VPS_IP} as ${VPS_USER}"

# ─── 1. Install Docker + Compose + Node.js ──────────────────────
echo "==> Step 1: Installing dependencies"
$SSH "$SSH_TARGET" bash -s <<'REMOTE_DEPS'
set -euo pipefail

# Install Docker
if ! command -v docker &>/dev/null; then
  echo "  Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2
  systemctl enable --now docker
fi

# Install Node.js 20
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi

echo "  Docker: $(docker --version)"
echo "  Compose: $(docker compose version)"
echo "  Node: $(node --version)"
echo "  npm: $(npm --version)"
REMOTE_DEPS

# ─── 2. Set up Traefik ──────────────────────────────────────────
echo "==> Step 2: Setting up Traefik"
$SSH "$SSH_TARGET" bash -s <<'REMOTE_TRAEFIK'
set -euo pipefail

# Create traefik network
docker network inspect traefik &>/dev/null || docker network create traefik

# Write Traefik compose file
cat > /opt/traefik/docker-compose.yml <<'EOF'
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
EOF

mkdir -p /opt/traefik

# Start Traefik (idempotent)
docker compose -f /opt/traefik/docker-compose.yml -p traefik up -d
echo "  Traefik is running"
REMOTE_TRAEFIK

# ─── 3. Copy spike service files ─────────────────────────────────
echo "==> Step 3: Copying spike service files"
$SSH "$SSH_TARGET" "mkdir -p ${VPS_WORKDIR}"
$SCP "$SCRIPT_DIR"/spike-service/spike.ts "$SSH_TARGET":"${VPS_WORKDIR}/"
$SCP "$SCRIPT_DIR"/spike-service/package.json "$SSH_TARGET":"${VPS_WORKDIR}/"
$SCP "$SCRIPT_DIR"/spike-service/tsconfig.json "$SSH_TARGET":"${VPS_WORKDIR}/"

# Write .env on VPS
$SSH "$SSH_TARGET" "cat > ${VPS_WORKDIR}/.env" <<EOF
WEBHOOK_SECRET=${WEBHOOK_SECRET}
BASE_DOMAIN=${BASE_DOMAIN}
PORT=3002
EOF

# ─── 4. Install npm deps ────────────────────────────────────────
echo "==> Step 4: Installing npm dependencies"
$SSH "$SSH_TARGET" "cd ${VPS_WORKDIR} && npm install"

# ─── 5. Install smee client + pm2 (or run in screen) ───────────
echo "==> Step 5: Setting up smee tunnel"
$SSH "$SSH_TARGET" bash -s <<REMOTE_SMEE
set -euo pipefail
cd /opt/pr-preview-spike
npm install --save-dev smee-client 2>/dev/null || true
REMOTE_SMEE

# ─── 6. Create systemd services ──────────────────────────────────
echo "==> Step 6: Creating systemd services"

$SSH "$SSH_TARGET" "cat > /etc/systemd/system/pr-preview-spike.service" <<SVC
[Unit]
Description=PR Preview Spike Service
After=network.target docker.service
Wants=network.target docker.service

[Service]
Type=simple
WorkingDirectory=${VPS_WORKDIR}
ExecStart=/usr/bin/npx ts-node spike.ts
EnvironmentFile=${VPS_WORKDIR}/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

$SSH "$SSH_TARGET" "cat > /etc/systemd/system/pr-preview-smee.service" <<SMEESVC
[Unit]
Description=Smee Webhook Proxy for PR Preview
After=network.target pr-preview-spike.service
Wants=network.target pr-preview-spike.service

[Service]
Type=simple
WorkingDirectory=${VPS_WORKDIR}
ExecStart=/usr/bin/npx smee -u ${SMEE_CHANNEL} -t http://localhost:3002/webhooks
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SMEESVC

$SSH "$SSH_TARGET" "systemctl daemon-reload"
$SSH "$SSH_TARGET" "systemctl enable pr-preview-spike.service pr-preview-smee.service"
$SSH "$SSH_TARGET" "systemctl restart pr-preview-spike.service pr-preview-smee.service"

# ─── 7. Verify ───────────────────────────────────────────────────
echo ""
echo "==> Waiting 3s for services to start..."
sleep 3

echo "Systemd status:"
$SSH "$SSH_TARGET" "systemctl status pr-preview-spike.service --no-pager --lines=5" || true
echo "---"
$SSH "$SSH_TARGET" "systemctl status pr-preview-smee.service --no-pager --lines=5" || true

echo ""
echo "==================================================================="
echo "  Provisioning complete!"
echo ""
echo "  Traefik:      http://${VPS_IP}"
echo "  Spike logs:   $SSH $SSH_TARGET 'journalctl -u pr-preview-spike -f'"
echo "  Smee logs:    $SSH $SSH_TARGET 'journalctl -u pr-preview-smee -f'"
echo ""
echo "  Webhook URL (use in GitHub App): ${SMEE_CHANNEL}"
echo ""
echo "  Next steps:"
echo "  1. Create the GitHub App (see SETUP.md)"
echo "  2. Create the sample app repo (see SETUP.md)"
echo "  3. Run the test flows (see SETUP.md)"
echo "==================================================================="
