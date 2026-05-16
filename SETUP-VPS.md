# Setup — VPS-Local (clone on server, run there)

> Script: `setup-vps.sh` | You are already on the VPS

## Overview

This spike validates 5 assumptions for a GitHub App PR preview system:

| # | Assumption | How we prove it |
|---|-----------|-----------------|
| 1 | GitHub App webhooks arrive reliably | Receive a real PR event, inspect payload |
| 2 | `docker compose` driven from Node.js | Script open/sync/close flows |
| 3 | Traefik routes PR-named containers correctly | Open browser, see preview at `pr-N.mypreviews.online` |
| 4 | Teardown works without `git clone` | Close PR, verify containers gone |
| 5 | Single-process serialization (no race) | Rapid-push: 3 pushes in quick succession |

---

## Step 1: Clone the repo on your VPS

```bash
ssh root@<your-vps-ip>
git clone <this-repo-url> /opt/pr-preview-spike
cd /opt/pr-preview-spike
```

---

## Step 2: Configure .env on the VPS

```bash
cp .env.template .env
# Edit .env with your values
```

Required fields:
- `WEBHOOK_SECRET` — generate with: `openssl rand -hex 32`
- `BASE_DOMAIN` — `mypreviews.online` (or your domain)
- `SMEE_CHANNEL` — get from https://smee.io (click "Start a new channel", copy the URL)

---

## Step 3: DNS Setup (on your DNS provider)

**Add a wildcard A record** for your domain:

```
*.mypreviews.online  →  <VPS_IP>
```

Verify: `dig pr-1.mypreviews.online` should resolve to your VPS IP.

---

## Step 4: Run the VPS setup script

```bash
sudo ./setup-vps.sh
```

This script installs and configures everything on the VPS:
1. Docker + Compose v2
2. Node.js 20
3. Traefik reverse proxy on ports 80/443
4. Spike service npm dependencies
5. Smee webhook tunnel
6. systemd services for both spike and smee

Verify it's running:

```bash
curl http://localhost:3002
# → "pr-preview spike service running"
```

Check logs:

```bash
journalctl -u pr-preview-spike -f
journalctl -u pr-preview-smee -f
```

---

## Step 5: Create the Sample App Repo

On your local machine (not the VPS):

```bash
cd sample-app
git init
git add .
git commit -m "Initial spike sample app"
git branch -M main
git remote add origin git@github.com:<your-username>/pr-preview-sample-app.git
git push -u origin main
```

---

## Step 6: Register the GitHub App

1. Go to **GitHub Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **GitHub App name**: `pr-preview-spike`
   - **Homepage URL**: `https://mypreviews.online`
   - **Webhook URL**: paste your **Smee channel URL** (from `.env`)
   - **Webhook secret**: paste your `WEBHOOK_SECRET` (from `.env`)
3. **Permissions**:
   - **Pull requests**: Read & Write
   - **Contents**: Read-only
4. **Subscribe to events**: **Pull request**
5. Create the app
6. **Generate a private key** (save it — not needed for this spike, but keep it)
7. Go to **Install App** → install on the `pr-preview-sample-app` repo

Verify webhook delivery:
- Watch logs on VPS: `journalctl -u pr-preview-spike -f`
- GitHub App settings → **Advanced** → check for successful deliveries

---

## Step 7: Run the 5 Test Flows

All commands below run on your local machine in the `sample-app` repo clone.

### Test 1: PR Opened

```bash
echo "// test" >> index.js
git checkout -b feature/test-pr
git add . && git commit -m "test: trigger pr preview"
git push -u origin feature/test-pr
gh pr create --title "Test PR preview" --body "Spike validation" --base main
```

**Verify:**
- [ ] Spike logs show `PR #1 | opened`
- [ ] `docker ps | grep app-pr-1` on VPS shows running container
- [ ] `curl http://localhost:40001` on VPS returns HTML
- [ ] `curl -H "Host: pr-1.mypreviews.online" http://localhost` on VPS routes through Traefik
- [ ] Browser: open `http://pr-1.mypreviews.online`

### Test 2: PR Synchronized (push new commit)

```bash
echo "// second change" >> index.js
git add . && git commit -m "test: second commit"
git push
```

**Verify:**
- [ ] Old container stack torn down (logs show "Tearing down existing pr-1")
- [ ] New stack built and started
- [ ] No port conflicts
- [ ] `curl http://localhost:40001` still works

### Test 3: Rapid Pushes (concurrency)

```bash
for i in 1 2 3; do
  echo "// rapid push $i" >> index.js
  git add . && git commit -m "test: rapid push $i"
done
git push
```

**Verify:**
- [ ] Webhooks arrive and are processed sequentially
- [ ] Final state is the latest commit
- [ ] Only ONE container for this PR running: `docker ps | grep app-pr-` has 1 match for this PR
- [ ] No orphaned containers

### Test 4: PR Closed

```bash
gh pr close <PR-number>
```

**Verify:**
- [ ] Spike logs show `PR #1 | closed`
- [ ] Containers removed: `docker ps | grep app-pr-1` returns empty
- [ ] No git clone happens (check logs — no clone step for closed action)

### Test 5: Branch Deleted Before Close

```bash
git checkout -b feature/test-delete-branch
echo "// branch delete test" >> index.js
git add . && git commit -m "test: delete branch"
git push -u origin feature/test-delete-branch
gh pr create --title "Test branch delete" --body "Will delete branch before close"

# Wait for preview to start, then delete the branch on GitHub
git push origin --delete feature/test-delete-branch

# Close the PR
gh pr close <PR-number>
```

**Verify:**
- [ ] Teardown still works (uses PR number from webhook — no clone)
- [ ] Containers removed: `docker ps | grep app-pr-` does not show this PR

---

## Step 8: Cleanup

On VPS:
```bash
sudo systemctl stop pr-preview-spike pr-preview-smee
docker ps --filter "name=app-pr-" --format '{{.Names}}' | xargs -r docker stop
docker ps -a --filter "name=app-pr-" --format '{{.Names}}' | xargs -r docker rm
```

On GitHub:
1. Delete the GitHub App (Settings → Developer settings → GitHub Apps)
2. Delete the sample app repo
3. Delete smee.io channel

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Smee shows "Connection refused" | Ensure spike service is running: `systemctl status pr-preview-spike` |
| Webhook not received | Check GitHub App → Advanced → Delivery logs |
| `docker compose` permission denied | Run `sudo ./setup-vps.sh` (services are systemd-managed as root) |
| Port 80/443 already in use | Stop conflicting service: `systemctl stop nginx` / `systemctl stop apache2` |
| Traefik doesn't route | Check container is on `traefik` network: `docker inspect app-pr-N` |
| `ts-node` not found | Run `npm install` in `/opt/pr-preview-spike/spike-service` |
| Git clone fails (auth) | Use HTTPS clone URL for public repos, or set up an SSH key on the VPS |
