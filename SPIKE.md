# Spike — GitHub App PR Preview

Goal: prove the GitHub App approach works end-to-end before committing to a full implementation. One day of work, throwaway code, validate the risky assumptions.

## What we're validating

| Assumption | How we prove it |
|------------|-----------------|
| GitHub App webhooks arrive reliably and carry enough data | Receive a real PR event, inspect payload |
| `docker compose` can be driven from Node.js with env vars from the webhook | Script the open/sync/close flows |
| Traefik picks up labels from PR-named containers and routes correctly | Open browser, see the preview |
| Teardown works without `git clone` (PR number from webhook only) | Close PR, verify containers gone |
| Concurrency is naturally serialized (single process, no race) | Rapid-push test: 3 pushes in quick succession |

## Spike plan (6 steps)

### 1. Stand up the VPS (30 min)

Use a fresh Ubuntu VPS (or local Docker host for faster iteration).

```bash
# Install Docker + Compose
apt update && apt install -y docker.io docker-compose-v2

# Create Traefik network
docker network create traefik

# Start Traefik
cat > docker-compose.yml <<'EOF'
services:
  traefik:
    image: traefik:v3.3
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./acme.json:/acme.json
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

touch acme.json && chmod 600 acme.json
docker compose up -d
```

For local testing without a domain, skip TLS and use `localhost` ports directly.

### 2. Create the sample app repo (30 min)

Create a new GitHub repo `pr-preview-sample-app` with a minimal web app that clearly identifies itself.

```
pr-preview-sample-app/
├── Dockerfile
├── docker-compose.pr.yml
├── index.js            ← minimal Node.js app
└── package.json
```

#### index.js — sample app

```js
const http = require("http");

const port = process.env.PORT || 3000;
const pr = process.env.PR_NUMBER || "local";

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`
    <!DOCTYPE html>
    <html>
    <head><title>PR #${pr} Preview</title>
    <style>
      body { font-family: system-ui; display: flex; justify-content: center;
             align-items: center; min-height: 100vh; margin: 0; }
      .card { border: 2px solid #3b82f6; border-radius: 12px; padding: 2rem;
              text-align: center; }
      h1 { color: #3b82f6; }
      .badge { background: #3b82f6; color: white; padding: 0.25rem 0.75rem;
               border-radius: 999px; font-size: 0.875rem; }
    </style></head>
    <body>
      <div class="card">
        <h1>PR Preview Environment</h1>
        <p>Pull Request <span class="badge">#${pr}</span></p>
        <p>Request path: <code>${req.url}</code></p>
      </div>
    </body></html>
  `);
});

server.listen(port, () => {
  console.log(`PR #${pr} preview listening on port ${port}`);
});
```

#### Dockerfile

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json .
RUN npm install
COPY index.js .
CMD ["node", "index.js"]
ENV PORT=3000
```

#### docker-compose.pr.yml

```yaml
services:
  app:
    build: .
    container_name: app-pr-${PR_NUMBER}
    ports:
      - "${PORT}:3000"
    environment:
      PR_NUMBER: ${PR_NUMBER}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app-pr-${PR_NUMBER}.rule=Host(`pr-${PR_NUMBER}.pr.example.com`)"
      - "traefik.http.services.app-pr-${PR_NUMBER}.loadbalancer.server.port=3000"
    networks:
      - traefik

networks:
  traefik:
    external: true
```

#### package.json

```json
{
  "name": "pr-preview-sample-app",
  "private": true,
  "scripts": {
    "start": "node index.js"
  }
}
```

### 3. Build the spike service (2 hours)

A single TypeScript file that does the bare minimum. No SQLite, no CLI, no PR comments — just receive webhook, run docker compose.

```
pr-preview-spike/
├── package.json
├── tsconfig.json
├── .env
└── spike.ts
```

#### spike.ts — minimal service

```ts
import { createServer, IncomingMessage, ServerResponse } from "http";
import { createHmac, timingSafeEqual } from "crypto";
import { execSync } from "child_process";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET!;
const BASE_DOMAIN = process.env.BASE_DOMAIN!;       // pr.example.com
const COMPOSE_FILE = process.env.COMPOSE_FILE!;       // path to docker-compose.pr.yml in infra repo
const PORT = parseInt(process.env.PORT || "3002", 10);

function verifySignature(payload: string, signature: string): boolean {
  const hmac = createHmac("sha256", WEBHOOK_SECRET);
  hmac.update(payload);
  const digest = `sha256=${hmac.digest("hex")}`;
  try {
    return timingSafeEqual(Buffer.from(digest), Buffer.from(signature));
  } catch {
    return false;
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

function log(msg: string) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function handleWebhook(req: IncomingMessage, res: ServerResponse) {
  const sig = req.headers["x-hub-signature-256"] as string;
  const event = req.headers["x-github-event"] as string;
  const body = await readBody(req);

  if (!sig || !verifySignature(body, sig)) {
    res.writeHead(401);
    res.end("invalid signature");
    return;
  }

  if (event !== "pull_request") {
    res.writeHead(200);
    res.end("ignored");
    return;
  }

  const payload = JSON.parse(body);
  const action: string = payload.action;
  const number: number = payload.number;
  const cloneUrl: string = payload.pull_request.head.repo.clone_url;
  const headRef: string = payload.pull_request.head.ref;
  const fullName: string = payload.pull_request.head.repo.full_name;

  log(`PR #${number} | ${action} | ${fullName}`);

  const projectName = `pr-${number}`;

  if (action === "opened" || action === "synchronize" || action === "reopened") {
    // Clone the PR branch
    const tmpDir = mkdtempSync(join(tmpdir(), "pr-preview-"));
    try {
      log(`  Cloning ${cloneUrl}#${headRef} into ${tmpDir}`);
      execSync(`git clone --depth 1 --branch "${headRef}" "${cloneUrl}" "${tmpDir}"`, {
        stdio: "pipe",
        timeout: 60000,
      });

      // Tear down any existing stack for this PR
      try {
        log(`  Tearing down existing ${projectName}`);
        execSync(`docker compose -f "${COMPOSE_FILE}" -p ${projectName} down --volumes`, {
          cwd: tmpDir,
          stdio: "pipe",
          timeout: 30000,
        });
      } catch {
        // No existing stack — fine
      }

      // Build
      log(`  Building ${projectName}`);
      execSync(
        `PR_NUMBER=${number} COMPOSE_PROJECT=${projectName} PORT=${
          40000 + number
        } docker compose -f "${COMPOSE_FILE}" -p ${projectName} build`,
        { cwd: tmpDir, stdio: "inherit", timeout: 120000 }
      );

      // Up
      log(`  Starting ${projectName}`);
      execSync(
        `PR_NUMBER=${number} COMPOSE_PROJECT=${projectName} PORT=${
          40000 + number
        } docker compose -f "${COMPOSE_FILE}" -p ${projectName} up --detach`,
        { cwd: tmpDir, stdio: "inherit", timeout: 60000 }
      );

      log(`  Done → https://pr-${number}.${BASE_DOMAIN}`);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  if (action === "closed") {
    try {
      log(`  Tearing down ${projectName}`);
      execSync(`docker compose -f "${COMPOSE_FILE}" -p ${projectName} down --volumes`, {
        stdio: "pipe",
        timeout: 30000,
      });
      log(`  ${projectName} removed`);
    } catch {
      log(`  No stack found for ${projectName}`);
    }
  }

  res.writeHead(200);
  res.end("ok");
}

const server = createServer((req, res) => {
  if (req.method === "POST" && req.url === "/webhooks") {
    handleWebhook(req, res).catch((err) => {
      log(`ERROR: ${err.message}`);
      res.writeHead(500);
      res.end("error");
    });
  } else {
    res.writeHead(200);
    res.end("pr-preview spike service running");
  }
});

server.listen(PORT, () => {
  log(`Spike service listening on port ${PORT}`);
  log(`Webhook URL: http://localhost:${PORT}/webhooks`);
});
```

#### .env

```env
WEBHOOK_SECRET=your-github-app-webhook-secret
BASE_DOMAIN=pr.example.com
COMPOSE_FILE=/path/to/sample-app/docker-compose.pr.yml
PORT=3002
```

### 4. Register a GitHub App and wire it up (30 min)

1. Go to **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Name: `pr-preview-spike`
3. Webhook URL: use `smee.io` or `ngrok` to expose the local service
   ```bash
   npx smee -u https://smee.io/your-channel -t http://localhost:3002/webhooks
   ```
4. Webhook secret: generate one, put in `.env`
5. Permissions:
   - Pull requests: Read & write
   - Contents: Read-only
6. Events: Pull requests
7. Generate a private key (not needed for this spike since we only verify incoming webhooks)
8. Install the app on the sample app repo

### 5. Test the flows (1 hour)

#### Test 1: PR opened

```
1. Create a PR on the sample app repo (any change)
2. Watch spike service logs
3. Verify:
   - Webhook received ✓
   - git clone succeeds ✓
   - docker compose build succeeds ✓
   - docker compose up succeeds ✓
   - Container running: docker ps | grep app-pr-
   - App responds: curl http://localhost:4000X
   - Traefik routes it (if domain set up): curl https://pr-N.pr.example.com
```

#### Test 2: PR synchronized (push new commit)

```
1. Push a new commit to the PR branch
2. Verify:
   - Old container stack is torn down ✓
   - New stack is built and started ✓
   - No port conflicts ✓
```

#### Test 3: Rapid pushes (concurrency)

```
1. Create 3 commits on the PR branch, push them rapidly
2. Verify:
   - Webhooks arrive sequentially (or service processes them in order) ✓
   - Final state is the latest commit ✓
   - No orphaned containers ✓
```

#### Test 4: PR closed

```
1. Close the PR (without merging)
2. Verify:
   - Webhook received (action: "closed") ✓
   - docker compose down runs ✓
   - Containers removed: docker ps | grep app-pr-N → empty ✓
   - No git clone needed ✓
```

#### Test 5: Branch deleted before close

```
1. Create a PR, then delete the branch on GitHub, then close the PR
2. Verify:
   - Teardown still works (uses PR number from webhook, not git clone) ✓
   - Containers removed ✓
```

### 6. Clean up (15 min)

```bash
# Stop spike service
# Tear down all test containers
docker compose -p pr-<N> down --volumes
# Delete GitHub App from settings
# Delete sample app repo
```

## Spike success criteria

Mark the spike as **successful** if all of these pass:

- [ ] PR opened → preview available at `http://localhost:4000X`
- [ ] PR sync → old stack replaced with new build
- [ ] PR closed → stack removed (no clone needed)
- [ ] Rapid 3-push → no race condition, final state correct
- [ ] Branch-deleted close → teardown still works
- [ ] Traefik routes to the correct container (if domain/DNS set up)

## Spike failure modes to watch for

| Failure | Mitigation |
|---------|------------|
| `docker compose` times out on large builds | Increase timeout, log build progress |
| Port conflicts between PR stacks | Use non-overlapping port ranges or skip host port mapping entirely (Traefik routes by container name) |
| Webhook latency > build time → GitHub retries duplicate event | Track in-flight builds in memory, deduplicate |
| `rmSync` on tmpDir fails (files in use) | Clean up clone dir after compose up, not immediately |
| Docker rate limits on `docker compose build` (frequent rebuilds) | Use image caching, `--build-arg BUILDKIT_INLINE_CACHE=1` |

## What to skip in the spike

These are out of scope for the spike and belong in the full implementation:

- SQLite state tracking
- PR comments / commit statuses
- CLI tool
- Health check + rollback
- Cleanup cron job
- systemd service file
- `.pr-preview.yml` repo config
- HTTPS / Let's Encrypt (use plain HTTP or Traefik's TLS later)
- Multi-service compose files (just one `app` service)
- Secrets management (hardcode for spike)

## After the spike

If successful, the SPIKE.md + spike.ts become the blueprint for the full implementation in the infra repo (`src/`). The throwaway spike code gets replaced with a proper TypeScript project structure (routes, services, error handling, tests).
