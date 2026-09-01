import https from "node:https";
import fs from "node:fs";

const get = (url, headers = {}) => new Promise((resolve, reject) => {
  https.get(url, { headers: { "User-Agent": "codex-via-server-compatibility-report", ...headers } }, (response) => {
    let body = "";
    response.on("data", (chunk) => { body += chunk; });
    response.on("end", () => response.statusCode >= 200 && response.statusCode < 300 ? resolve(JSON.parse(body)) : reject(new Error(`HTTP ${response.statusCode}`)));
  }).on("error", reject);
});

const compatibility = JSON.parse(fs.readFileSync(new URL("../compatibility.json", import.meta.url)));
const npm = await get("https://registry.npmjs.org/@openai%2fcodex/latest");
const release = await get("https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest", { Accept: "application/vnd.github+json" });
console.log(JSON.stringify({ configured_codex: compatibility.codex.candidates, latest_codex: npm.version, configured_cliproxyapi: compatibility.cliproxyapi.last_tested, latest_cliproxyapi: release.tag_name?.replace(/^v/, "") }, null, 2));
