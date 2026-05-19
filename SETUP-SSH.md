# Setup — SSH-Remote (provision from your local machine)

> Script: `provision.sh` | You are on your local machine, VPS is remote

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

## Step 1: Configure .env on your local machine

```bash
cp .env.template .env
# Edit .env with your values
```

Required fields:
- `VPS_IP` — your VPS public IP
- `VPS_USER` — SSH user (usually `root`)
- `SSH_KEY_PATH` — (optional) path to SSH private key
- `WEBHOOK_SECRET` — generate with: `openssl rand -hex 32`
- `BASE_DOMAIN` — `mypreviews.online` (or your domain)
- `ACME_EMAIL` — your email for Let's Encrypt certificate issuance

---

## Step 2: DNS Setup (on your DNS provider)

Add two records pointing to your VPS IP:

```
mypreviews.online       →  <VPS_IP>      (A - for Let's Encrypt + webhook)
*.mypreviews.online     →  <VPS_IP>      (A - wildcard, for PR previews)
```

Verify: `dig pr-1.mypreviews.online` and `dig mypreviews.online` should resolve to your VPS IP.

---

## Step 3: Run the provisioning script

```bash
chmod +x provision.sh
./provision.sh
```

This script SSHs into the VPS and:
1. Installs Docker + Compose v2 + Node.js 20
2. Creates the Traefik Docker network and starts Traefik on ports 80/443 with Let's Encrypt
3. Copies the spike service files to `/opt/pr-preview-spike` on the VPS
4. Installs npm dependencies
5. Sets up a `systemd` service for the spike (`pr-preview-spike.service`)

Verify it's running:

```bash
curl http://<VPS_IP>:3002
# → "pr-preview spike service running"
```

Check logs:

```bash
ssh <VPS_USER>@<VPS_IP> 'journalctl -u pr-preview-spike -f'
```

---

## Step 4: Create the Sample App Repo

On your local machine:

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

## Step 5: Register the GitHub App

1. Go to **GitHub Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **GitHub App name**: `pr-preview-spike`
   - **Homepage URL**: `https://mypreviews.online`
   - **Webhook URL**: `https://mypreviews.online/webhooks`
   - **Webhook secret**: paste your `WEBHOOK_SECRET` (from `.env`)
3. **Permissions**:
   - **Pull requests**: Read & Write
   - **Contents**: Read-only
4. **Subscribe to events**: **Pull request**
5. Create the app
6. **Generate a private key** (save it — not needed for this spike, but keep it)
7. Go to **Install App** → install on the `pr-preview-sample-app` repo

Verify webhook delivery:
- Watch VPS logs: `ssh <VPS_USER>@<VPS_IP> 'journalctl -u pr-preview-spike -f'`
- GitHub App settings → **Advanced** → check for successful deliveries

---

## Step 6: Run the 5 Test Flows

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
- [ ] On VPS: `docker ps | grep app-pr-1` shows running container
- [ ] On VPS: `curl http://localhost:40001` returns HTML
- [ ] On VPS: `curl -H "Host: pr-1.mypreviews.online" http://localhost` routes through Traefik
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
- [ ] `curl http://<VPS_IP>:40001` still works

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
- [ ] Only ONE container for this PR running: `ssh ... "docker ps | grep app-pr-"` has 1 match
- [ ] No orphaned containers

### Test 4: PR Closed

```bash
gh pr close <PR-number>
```

**Verify:**
- [ ] Spike logs show `PR #1 | closed`
- [ ] Containers removed: `ssh ... "docker ps | grep app-pr-1"` returns empty
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
- [ ] Containers removed: `ssh ... "docker ps | grep app-pr-"` does not show this PR

---

## Step 7: Cleanup

On VPS:
```bash
ssh <VPS_USER>@<VPS_IP> 'systemctl stop pr-preview-spike'
ssh <VPS_USER>@<VPS_IP> 'docker ps --filter "name=app-pr-" --format "{{.Names}}" | xargs -r docker stop'
ssh <VPS_USER>@<VPS_IP> 'docker ps -a --filter "name=app-pr-" --format "{{.Names}}" | xargs -r docker rm'
```

On GitHub:
1. Delete the GitHub App (Settings → Developer settings → GitHub Apps)
2. Delete the sample app repo

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `provision.sh` can't connect | Check VPS_IP, VPS_USER in `.env`; verify SSH key or password auth works |
| Webhook delivery fails | Ensure DNS `A` record for `mypreviews.online` resolves; check GitHub App → Advanced → Delivery logs |
| Let's Encrypt certificate not issued | Ensure port 80 is reachable from internet; check Traefik logs: `docker logs traefik-traefik-1` |
| Webhook not received | Check GitHub App → Advanced → Delivery logs; verify webhook URL is `https://mypreviews.online/webhooks` |
| `docker compose` permission denied | SSH in and add user to docker group: `usermod -aG docker $USER` |
| Port 80/443 already in use | SSH in and stop nginx/apache: `systemctl stop nginx` |
| Traefik doesn't route | SSH in and check container is on `traefik` network: `docker inspect app-pr-N` |
| `ts-node` not found | SSH in and run `npm install` in `/opt/pr-preview-spike` |
| Git clone fails (auth) | Use HTTPS clone URL for public repos, or set up an SSH key on the VPS |
