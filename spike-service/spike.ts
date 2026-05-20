import { createServer, IncomingMessage, ServerResponse } from "http";
import { createHmac, timingSafeEqual } from "crypto";
import { execSync } from "child_process";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET!;
const BASE_DOMAIN = process.env.BASE_DOMAIN!;
const PORT = parseInt(process.env.PORT || "3002", 10);
const USE_SSH_CLONE = process.env.USE_SSH_CLONE === "true";

function toSshUrl(httpsUrl: string): string {
  // https://github.com/owner/repo.git -> git@github.com:owner/repo.git
  return httpsUrl.replace(/^https:\/\/github\.com\//, "git@github.com:");
}

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
    const tmpDir = mkdtempSync(join(tmpdir(), "pr-preview-"));
    try {
      const url = USE_SSH_CLONE ? toSshUrl(cloneUrl) : cloneUrl;
      log(`  Cloning ${url}#${headRef} into ${tmpDir}`);
      execSync(`git clone --depth 1 --branch "${headRef}" "${url}" "${tmpDir}"`, {
        stdio: "pipe",
        timeout: 60000,
      });

      // Tear down any existing stack for this PR
      try {
        log(`  Tearing down existing ${projectName}`);
        execSync(`docker compose -p ${projectName} down --volumes`, {
          stdio: "pipe",
          timeout: 30000,
        });
      } catch {
        // No existing stack — fine
      }

      // Build
      log(`  Building ${projectName}`);
      execSync(
        `PR_NUMBER=${number} PORT=${
          40000 + number
        } docker compose -f docker-compose.pr.yml -p ${projectName} build`,
        { cwd: tmpDir, stdio: "inherit", timeout: 120000 }
      );

      // Up
      log(`  Starting ${projectName}`);
      execSync(
        `PR_NUMBER=${number} PORT=${
          40000 + number
        } docker compose -f docker-compose.pr.yml -p ${projectName} up --detach`,
        { cwd: tmpDir, stdio: "inherit", timeout: 60000 }
      );

      log(`  Done -> http://pr-${number}.${BASE_DOMAIN}`);
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  if (action === "closed") {
    try {
      log(`  Tearing down ${projectName}`);
      execSync(`docker compose -p ${projectName} down --volumes`, {
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
  log(`Webhook URL: https://${BASE_DOMAIN}/webhooks`);
});
