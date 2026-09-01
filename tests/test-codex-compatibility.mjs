import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { spawn, spawnSync } from "node:child_process";

const codexBinary = process.argv[2];
const expectedVersion = process.argv[3] ?? "";
if (!codexBinary) throw new Error("usage: node tests/test-codex-compatibility.mjs <codex> [version]");

const runtime = fs.mkdtempSync(path.join(os.tmpdir(), "codex-compatibility-"));
const codexHome = path.join(runtime, "codex-home");
const state = path.join(runtime, "state");
fs.mkdirSync(codexHome);
fs.mkdirSync(state);

const server = http.createServer((request, response) => {
  if (request.url !== "/v1/responses" || request.method !== "POST") {
    response.writeHead(404);
    response.end();
    return;
  }
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    const body = Buffer.concat(chunks);
    fs.writeFileSync(path.join(state, "request.json"), body);
    fs.writeFileSync(path.join(state, "headers.json"), JSON.stringify(request.headers));
    const requestBody = JSON.parse(body);
    const model = requestBody.model ?? "gpt-5.6-luna";
    const item = { id: "msg_compat", type: "message", status: "completed", role: "assistant", content: [{ type: "output_text", text: "OK", annotations: [], logprobs: [] }] };
    const usage = { input_tokens: 10, input_tokens_details: { cached_tokens: 0 }, output_tokens: 1, output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 11 };
    const responseObject = (status, output, responseUsage) => ({ id: "resp_compat", object: "response", created_at: Math.floor(Date.now() / 1000), status, background: false, error: null, incomplete_details: null, instructions: null, max_output_tokens: null, model, output, parallel_tool_calls: true, previous_response_id: null, reasoning: { effort: null, summary: null }, service_tier: "default", store: false, temperature: 1, text: { format: { type: "text" }, verbosity: "medium" }, tool_choice: "auto", tools: [], top_p: 1, truncation: "disabled", usage: responseUsage, user: null, metadata: {} });
    const events = [
      { type: "response.created", response: responseObject("in_progress", [], null) },
      { type: "response.output_item.added", output_index: 0, item: { ...item, status: "in_progress", content: [] } },
      { type: "response.content_part.added", item_id: item.id, output_index: 0, content_index: 0, part: { type: "output_text", text: "", annotations: [], logprobs: [] } },
      { type: "response.output_text.delta", item_id: item.id, output_index: 0, content_index: 0, delta: "OK", logprobs: [] },
      { type: "response.output_text.done", item_id: item.id, output_index: 0, content_index: 0, text: "OK", logprobs: [] },
      { type: "response.content_part.done", item_id: item.id, output_index: 0, content_index: 0, part: item.content[0] },
      { type: "response.output_item.done", output_index: 0, item },
      { type: "response.completed", response: responseObject("completed", [item], usage) },
    ];
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "close" });
    for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`);
    response.end();
  });
});

const cleanup = () => { server.close(); fs.rmSync(runtime, { recursive: true, force: true }); };
process.on("exit", cleanup);
process.on("SIGINT", () => process.exit(130));
process.on("SIGTERM", () => process.exit(143));

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
fs.writeFileSync(path.join(codexHome, "compat.config.toml"), `model_provider = "server_cliproxy"\n\n[model_providers.server_cliproxy]\nname = "Codex compatibility mock"\nbase_url = "http://127.0.0.1:${port}/v1"\nwire_api = "responses"\nsupports_websockets = false\nenv_key = "COMPATIBILITY_API_KEY"\n`);

const version = spawnSync(codexBinary, ["--profile", "compat", "--version"], { env: { ...process.env, CODEX_HOME: codexHome }, encoding: "utf8" });
if (version.status !== 0) throw new Error(`Codex version check failed: ${version.stderr}`);
if (expectedVersion && !version.stdout.includes(expectedVersion)) throw new Error(`Expected Codex ${expectedVersion}, got ${version.stdout}`);

const lastMessage = path.join(runtime, "last-message.txt");
const args = ["--profile", "compat", "exec", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "--model", "gpt-5.6-luna", "--output-last-message", lastMessage, "Reply only OK."];
const childEnv = { ...process.env, CODEX_HOME: codexHome, COMPATIBILITY_API_KEY: "compatibility-test-key" };
delete childEnv.OPENAI_API_KEY;
delete childEnv.SERVER_CODEX_API_KEY;
delete childEnv.CLIPROXY_API_KEY;
const child = spawn(codexBinary, args, { env: childEnv, shell: process.platform === "win32" });
let output = "";
child.stdout.on("data", (chunk) => { output += chunk; });
child.stderr.on("data", (chunk) => { output += chunk; });
const exitCode = await Promise.race([new Promise((resolve) => child.on("close", resolve)), new Promise((_, reject) => setTimeout(() => { child.kill("SIGTERM"); reject(new Error(`Codex request timed out: ${output}`)); }, 30000))]);
if (exitCode !== 0) throw new Error(`Codex request failed with ${exitCode}: ${output}`);
if (fs.readFileSync(lastMessage, "utf8").trim() !== "OK") throw new Error("Codex final message was not OK");
const requestBody = JSON.parse(fs.readFileSync(path.join(state, "request.json"), "utf8"));
if (requestBody.stream !== true || requestBody.model !== "gpt-5.6-luna") throw new Error("Unexpected compatibility request");
const headers = JSON.parse(fs.readFileSync(path.join(state, "headers.json"), "utf8"));
if (headers.authorization !== "Bearer compatibility-test-key") throw new Error("Compatibility request had unexpected Authorization");
console.log(`PASS: official Codex ${version.stdout.trim()} parsed profile and completed mock Responses`);
