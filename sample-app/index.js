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
