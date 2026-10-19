// Tests of app/javascript/check_client.js against a local HTTP server that
// answers like the dpplint API, a proxy in front of it, or not at all.
// Run with: node --test test/javascript/check_client.test.js (part of bin/rails test).
const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const path = require("node:path");
const { runCheck, failureText } = require(path.join(__dirname, "../../app/javascript/check_client.js"));

const TIMEOUT = 400;
let server;
let base;
const open = new Set();

// Path -> handler(req, res). A handler that does nothing never answers.
const routes = {
  "/ok": (req, res) => send(res, 200, "application/json; charset=utf-8", JSON.stringify({ summary: { passed: 5 }, accept: req.headers.accept })),
  "/proxy-503": (req, res) => send(res, 503, "text/html", "<html><head><title>503 Service Temporarily Unavailable</title></head></html>"),
  "/api-503": (req, res) => send(res, 503, "application/json", JSON.stringify({ error: "SOyA web-cli not reachable" })),
  "/api-400": (req, res) => send(res, 400, "application/json", JSON.stringify({ error: "productId is not an HTTP(S) URL" })),
  "/api-500-no-error": (req, res) => send(res, 500, "application/json", "{}"),
  "/html-200": (req, res) => send(res, 200, "text/html; charset=utf-8", "<!doctype html><title>Maintenance</title>"),
  "/no-type-502": (req, res) => { res.writeHead(502); res.end("Bad Gateway"); },
  "/broken-json": (req, res) => send(res, 200, "application/json", '{"summary": '),
  "/hang": () => {},
  "/hang-body": (req, res) => { res.writeHead(200, { "Content-Type": "application/json" }); res.write('{"summary": '); },
  "/slow-ok": (req, res) => setTimeout(() => send(res, 200, "application/json", '{"ok":1}'), 100),
};

function send(res, status, type, body) {
  res.writeHead(status, { "Content-Type": type, "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

test.before(async () => {
  server = http.createServer((req, res) => (routes[req.url] || ((q, r) => send(r, 404, "text/plain", "no route")))(req, res));
  server.on("connection", (socket) => { open.add(socket); socket.on("close", () => open.delete(socket)); });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

test.after(() => {
  open.forEach((socket) => socket.destroy());
  server.close();
});

const check = (route) => runCheck(base + route, { timeoutMs: TIMEOUT });

const timed = async (fn) => {
  const started = Date.now();
  const value = await fn();
  return [value, Date.now() - started];
};

test("a JSON result is returned, requested with Accept: application/json", async () => {
  const outcome = await check("/ok");
  assert.deepEqual(outcome, { ok: true, data: { summary: { passed: 5 }, accept: "application/json" } });
});

test("a result within the time limit is returned", async () => {
  assert.deepEqual(await check("/slow-ok"), { ok: true, data: { ok: 1 } });
});

test("error status: an HTML error page of a proxy (503) is reported with its status, not parsed", async () => {
  const outcome = await check("/proxy-503");
  assert.deepEqual(outcome, { ok: false, kind: "no_result", status: 503, contentType: "text/html" });
  assert.equal(failureText(outcome, 40000),
    "The DPP Linter answered with HTTP\u00a0503 and no result. The service may be restarting or busy; try again in a moment.");
});

test("error status: an error of the API (503 with JSON) is reported with its status and its message", async () => {
  const outcome = await check("/api-503");
  assert.deepEqual(outcome, { ok: false, kind: "http", status: 503, error: "SOyA web-cli not reachable" });
  assert.equal(failureText(outcome, 40000), "The DPP Linter answered with HTTP\u00a0503: SOyA web-cli not reachable");
});

test("error status: a rejected request (400) shows the reason given by the API", async () => {
  const outcome = await check("/api-400");
  assert.equal(outcome.kind, "http");
  assert.equal(failureText(outcome, 40000), "The DPP Linter answered with HTTP\u00a0400: productId is not an HTTP(S) URL");
});

test("error status: an error without a message still names the status", async () => {
  const outcome = await check("/api-500-no-error");
  assert.equal(failureText(outcome, 40000), "The DPP Linter answered with HTTP\u00a0500.");
});

test("error status: an answer without content type is reported with its status", async () => {
  const outcome = await check("/no-type-502");
  assert.deepEqual(outcome, { ok: false, kind: "no_result", status: 502, contentType: "" });
  assert.match(failureText(outcome, 40000), /^The DPP Linter answered with HTTP\u00a0502 and no result\./);
});

test("no JSON: an HTML page with HTTP 200 is not read as a result", async () => {
  const outcome = await check("/html-200");
  assert.deepEqual(outcome, { ok: false, kind: "no_result", status: 200, contentType: "text/html; charset=utf-8" });
  assert.equal(failureText(outcome, 40000),
    "The DPP Linter answered with HTTP\u00a0200 but without a result (text/html; charset=utf-8).");
});

test("no JSON: a JSON content type with a broken body is reported, not thrown", async () => {
  const outcome = await check("/broken-json");
  assert.deepEqual(outcome, { ok: false, kind: "invalid_json", status: 200, contentType: "application/json" });
  assert.equal(failureText(outcome, 40000), "The DPP Linter answered with HTTP\u00a0200, but its result could not be read.");
});

test("timeout: no answer ends the wait after the time limit", async () => {
  const [outcome, took] = await timed(() => check("/hang"));
  assert.deepEqual(outcome, { ok: false, kind: "timeout" });
  assert.ok(took >= TIMEOUT - 20 && took < TIMEOUT + 1000, `waited ${took} ms`);
  assert.equal(failureText(outcome, 40000),
    "The DPP Linter did not answer within 40\u00a0s, so the page stopped waiting. A slow passport host or a slow DID check can cause this.");
});

test("timeout: an answer that stops in the middle of the body ends the wait after the time limit", async () => {
  const [outcome, took] = await timed(() => check("/hang-body"));
  assert.deepEqual(outcome, { ok: false, kind: "timeout" });
  assert.ok(took < TIMEOUT + 1000, `waited ${took} ms`);
});

test("not reachable: no connection is reported as such, without waiting for the time limit", async () => {
  const closed = http.createServer();
  await new Promise((resolve) => closed.listen(0, "127.0.0.1", resolve));
  const port = closed.address().port;
  await new Promise((resolve) => closed.close(resolve));
  const [outcome, took] = await timed(() => runCheck(`http://127.0.0.1:${port}/x`, { timeoutMs: 5000 }));
  assert.deepEqual(outcome, { ok: false, kind: "unreachable" });
  assert.ok(took < 2000, `waited ${took} ms`);
  assert.equal(failureText(outcome, 40000), "The DPP Linter could not be reached. Check your connection, or try again in a moment.");
});
