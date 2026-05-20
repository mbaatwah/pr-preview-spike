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
: "${ACME_EMAIL:?Set ACME_EMAIL in .env}"

USE_SSH_CLONE="${USE_SSH_CLONE:-true}"
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

# ─── 0. Generate SSH key for GitHub cloning ──────────────────────
if [ "${USE_SSH_CLONE}" = "true" ]; then
  echo "==> Step 0: SSH key for GitHub"
  $SSH "$SSH_TARGET" bash -s <<'REMOTE_SSH'
set -euo pipefail
KEY_FILE="${HOME}/.ssh/id_ed25519"
if [ ! -f "${KEY_FILE}" ]; then
  mkdir -p "$(dirname "${KEY_FILE}")"
  ssh-keygen -t ed25519 -C "pr-preview-spike@VPS" -f "${KEY_FILE}" -N ""
  echo "  Generated: ${KEY_FILE}"
fi
echo "  Public key:"
echo ""
cat "${KEY_FILE}.pub"
echo ""
echo "  Add this key to GitHub:"
echo "    Repo → Settings → Deploy keys → Add deploy key"
echo "    OR  → https://github.com/settings/keys  (account-wide)"
REMOTE_SSH
fi

# ─── 1. Install Docker + Compose + Node.js ──────────────────────
echo "==> Step 1: Installing dependencies"
$SSH "$SSH_TARGET" bash -s <<'REMOTE_DEPS'
set -euo pipefail

if ! command -v docker &>/dev/null; then
  echo "  Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2
  systemctl enable --now docker
fi

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
$SSH "$SSH_TARGET" "docker network inspect traefik &>/dev/null || docker network create traefik"
$SSH "$SSH_TARGET" "mkdir -p /opt/traefik/dynamic"
$SSH "$SSH_TARGET" "touch /opt/traefik/acme.json && chmod 600 /opt/traefik/acme.json"

$SSH "$SSH_TARGET" "cat > /opt/traefik/docker-compose.yml" <<COMPOSE
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

$SSH "$SSH_TARGET" "cat > /opt/traefik/dynamic/webhooks.yml" <<DYNAMIC
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

$SSH "$SSH_TARGET" bash -s <<'RESTART_TRAEFIK'
if docker ps --format '{{.Names}}' | grep -q 'traefik'; then
  echo "  Tearing down existing Traefik..."
  docker compose -f /opt/traefik/docker-compose.yml -p traefik down
fi
docker compose -f /opt/traefik/docker-compose.yml -p traefik up -d
echo "  Traefik is running"
RESTART_TRAEFIK

# ─── 3. Copy spike service files ─────────────────────────────────
echo "==> Step 3: Copying spike service files"
$SSH "$SSH_TARGET" "mkdir -p ${VPS_WORKDIR}"
$SCP "$SCRIPT_DIR"/spike-service/spike.ts "$SSH_TARGET":"${VPS_WORKDIR}/"
$SCP "$SCRIPT_DIR"/spike-service/package.json "$SSH_TARGET":"${VPS_WORKDIR}/"
$SCP "$SCRIPT_DIR"/spike-service/tsconfig.json "$SSH_TARGET":"${VPS_WORKDIR}/"

$SSH "$SSH_TARGET" "cat > ${VPS_WORKDIR}/.env" <<EOF
WEBHOOK_SECRET=${WEBHOOK_SECRET}
BASE_DOMAIN=${BASE_DOMAIN}
PORT=3002
USE_SSH_CLONE=${USE_SSH_CLONE}
EOF

# ─── 4. Install npm deps ────────────────────────────────────────
echo "==> Step 4: Installing npm dependencies"
$SSH "$SSH_TARGET" "cd ${VPS_WORKDIR} && npm install"

# ─── 5. Create systemd service ───────────────────────────────────
echo "==> Step 5: Creating systemd service"

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

# Remove old smee service
$SSH "$SSH_TARGET" "systemctl stop pr-preview-smee.service 2>/dev/null || true; systemctl disable pr-preview-smee.service 2>/dev/null || true; rm -f /etc/systemd/system/pr-preview-smee.service"

$SSH "$SSH_TARGET" "systemctl daemon-reload"
$SSH "$SSH_TARGET" "systemctl enable pr-preview-spike.service"
$SSH "$SSH_TARGET" "systemctl restart pr-preview-spike.service"

# ─── 6. Verify ───────────────────────────────────────────────────
echo ""
echo "==> Waiting 3s for services to start..."
sleep 3

echo "Systemd status:"
$SSH "$SSH_TARGET" "systemctl status pr-preview-spike.service --no-pager --lines=5" || true

echo ""
echo "==================================================================="
echo "  Provisioning complete!"
echo ""
echo "  Traefik:      http://${VPS_IP}"
echo "  Spike logs:   $SSH $SSH_TARGET 'journalctl -u pr-preview-spike -f'"
echo ""
echo "  Webhook URL (use in GitHub App): https://${BASE_DOMAIN}/webhooks"
echo "  App preview: http://pr-N.${BASE_DOMAIN}"
echo ""
echo "  Next steps:"
echo "  1. Create the GitHub App (see SETUP-SSH.md)"
echo "  2. Create the sample app repo (see SETUP-SSH.md)"
echo "  3. Run the test flows (see SETUP-SSH.md)"
echo "==================================================================="
