const http = require("http");

const port = 3000;
const worktree = process.env.WORKTREE_NAME || "unknown";
const project = process.env.PROJECT_NAME || "unknown";
const dbUrl = process.env.DATABASE_URL || "not configured";

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/html" });
  res.end(`
    <h1>devcontainer-wt</h1>
    <table>
      <tr><td><strong>Project</strong></td><td>${project}</td></tr>
      <tr><td><strong>Worktree</strong></td><td>${worktree}</td></tr>
      <tr><td><strong>Database URL</strong></td><td>${dbUrl}</td></tr>
      <tr><td><strong>Hostname</strong></td><td>${require("os").hostname()}</td></tr>
    </table>
    <p><em>Served from container app-${project}-${worktree}</em></p>
  `);
});

server.listen(port, () => {
  console.log(`[devcontainer-wt] Server running on port ${port}`);
  console.log(`[devcontainer-wt] Worktree: ${worktree}, Project: ${project}`);
});
