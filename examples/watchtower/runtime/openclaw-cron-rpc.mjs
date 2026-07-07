#!/usr/bin/env node
// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-FileCopyrightText: Copyright (c) 2026, Tavily AI. All rights reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Minimal OpenClaw Gateway cron client for NemoClaw sandboxes. The regular
// `openclaw cron ...` CLI requires a paired CLI device; NemoClaw sandboxes are
// already configured for the Control UI path, so this client authenticates like
// the dashboard and calls the cron RPC methods directly. It uses a tiny local
// ws:// client so it can set the Origin header expected by Control UI auth.

import net from "node:net";
import { randomBytes, randomUUID } from "node:crypto";

const PROTOCOL_VERSION = 4;
const DEFAULT_URL = "ws://127.0.0.1:18789";
const DEFAULT_ORIGIN = "http://127.0.0.1:18789";
const CONNECT_TIMEOUT_MS = 10000;
const REQUEST_TIMEOUT_MS = 30000;

const url = process.env.OPENCLAW_GATEWAY_URL || DEFAULT_URL;
const token = process.env.OPENCLAW_GATEWAY_TOKEN;
const origin = process.env.OPENCLAW_CONTROL_UI_ORIGIN || DEFAULT_ORIGIN;

function die(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseDurationMs(value) {
  const raw = String(value || "").trim();
  const match = raw.match(/^(\d+(?:\.\d+)?)(ms|s|m|h|d)$/i);
  if (!match) die(`Invalid duration '${raw}'. Use e.g. 5m, 1h, 1d.`);
  const n = Number.parseFloat(match[1]);
  if (!Number.isFinite(n) || n <= 0) die(`Invalid duration '${raw}'.`);
  const unit = match[2].toLowerCase();
  const factor = unit === "ms" ? 1 : unit === "s" ? 1000 : unit === "m" ? 60000 : unit === "h" ? 3600000 : 86400000;
  return Math.floor(n * factor);
}

function parseArgs(argv) {
  const [op, ...rest] = argv;
  const opts = {};
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (!arg.startsWith("--")) die(`Unexpected argument: ${arg}`);
    const key = arg.slice(2);
    const next = rest[i + 1];
    if (next == null || next.startsWith("--")) opts[key] = true;
    else {
      opts[key] = next;
      i += 1;
    }
  }
  return { op, opts };
}

class LocalWebSocket {
  constructor(rawUrl) {
    const parsed = new URL(rawUrl);
    if (parsed.protocol !== "ws:") die(`Only ws:// gateway URLs are supported by this helper, got ${rawUrl}`);
    this.host = parsed.hostname;
    this.port = Number(parsed.port || 80);
    this.path = `${parsed.pathname || "/"}${parsed.search || ""}`;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.handshook = false;
    this.onText = () => {};
    this.onClose = () => {};
  }

  connect() {
    return new Promise((resolve, reject) => {
      const key = randomBytes(16).toString("base64");
      const timer = setTimeout(() => reject(new Error(`Gateway connect timeout: ${url}`)), CONNECT_TIMEOUT_MS);
      this.socket = net.connect({ host: this.host, port: this.port }, () => {
        this.socket.write([
          `GET ${this.path || "/"} HTTP/1.1`,
          `Host: ${this.host}:${this.port}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Key: ${key}`,
          "Sec-WebSocket-Version: 13",
          `Origin: ${origin}`,
          "",
          "",
        ].join("\r\n"));
      });
      this.socket.on("data", (chunk) => {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        if (!this.handshook) {
          const end = this.buffer.indexOf("\r\n\r\n");
          if (end === -1) return;
          const header = this.buffer.slice(0, end).toString("utf8");
          this.buffer = this.buffer.slice(end + 4);
          if (!header.startsWith("HTTP/1.1 101")) {
            clearTimeout(timer);
            reject(new Error(`WebSocket upgrade failed:\n${header}`));
            this.socket.destroy();
            return;
          }
          this.handshook = true;
          clearTimeout(timer);
          resolve();
        }
        this.parseFrames();
      });
      this.socket.on("error", (err) => reject(err));
      this.socket.on("close", () => this.onClose());
    });
  }

  parseFrames() {
    while (this.buffer.length >= 2) {
      const b0 = this.buffer[0];
      const b1 = this.buffer[1];
      const opcode = b0 & 0x0f;
      const masked = Boolean(b1 & 0x80);
      let len = b1 & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (this.buffer.length < offset + 2) return;
        len = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (len === 127) {
        if (this.buffer.length < offset + 8) return;
        const high = this.buffer.readUInt32BE(offset);
        const low = this.buffer.readUInt32BE(offset + 4);
        if (high !== 0) throw new Error("WebSocket frame too large");
        len = low;
        offset += 8;
      }
      let mask;
      if (masked) {
        if (this.buffer.length < offset + 4) return;
        mask = this.buffer.slice(offset, offset + 4);
        offset += 4;
      }
      if (this.buffer.length < offset + len) return;
      let payload = this.buffer.slice(offset, offset + len);
      this.buffer = this.buffer.slice(offset + len);
      if (masked && mask) {
        payload = Buffer.from(payload);
        for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      }
      if (opcode === 1) this.onText(payload.toString("utf8"));
      else if (opcode === 8) this.close();
      else if (opcode === 9) this.sendFrame(0xA, payload);
    }
  }

  send(text) {
    this.sendFrame(1, Buffer.from(text, "utf8"));
  }

  sendFrame(opcode, payload) {
    const len = payload.length;
    const headerLen = len < 126 ? 2 : len <= 0xffff ? 4 : 10;
    const header = Buffer.alloc(headerLen + 4);
    header[0] = 0x80 | opcode;
    if (len < 126) {
      header[1] = 0x80 | len;
    } else if (len <= 0xffff) {
      header[1] = 0x80 | 126;
      header.writeUInt16BE(len, 2);
    } else {
      header[1] = 0x80 | 127;
      header.writeUInt32BE(0, 2);
      header.writeUInt32BE(len, 6);
    }
    const maskOffset = headerLen;
    const mask = randomBytes(4);
    mask.copy(header, maskOffset);
    const masked = Buffer.from(payload);
    for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4];
    this.socket.write(Buffer.concat([header, masked]));
  }

  close() {
    try { this.socket?.end(); } catch {}
  }
}

class GatewayRpc {
  constructor() {
    if (!token) die("OPENCLAW_GATEWAY_TOKEN is required inside the sandbox.", 2);
    this.ws = new LocalWebSocket(url);
    this.pending = new Map();
  }

  async ready() {
    await this.ws.connect();
    this.ws.onText = (text) => this.handleMessage(text);
    await this.request("connect", {
      minProtocol: PROTOCOL_VERSION,
      maxProtocol: PROTOCOL_VERSION,
      client: {
        id: "openclaw-control-ui",
        version: "watchtower-example",
        platform: "linux",
        mode: "webchat",
        instanceId: `watchtower-${Date.now()}`,
      },
      role: "operator",
      scopes: ["operator.admin", "operator.approvals", "operator.pairing"],
      caps: [],
      auth: { token },
      userAgent: "watchtower-example",
      locale: "en-US",
    });
  }

  handleMessage(text) {
    let msg;
    try { msg = JSON.parse(text); } catch { return; }
    if (msg.type === "event") return;
    if (msg.type !== "res") return;
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    if (msg.ok) pending.resolve(msg.payload);
    else pending.reject(new Error(`${msg.error?.code || "ERROR"}: ${msg.error?.message || "request failed"}`));
  }

  request(method, params) {
    const id = randomUUID();
    this.ws.send(JSON.stringify({ type: "req", id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timeout waiting for ${method}`));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(id, {
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (err) => { clearTimeout(timer); reject(err); },
      });
    });
  }

  close() { this.ws.close(); }
}

async function main() {
  const { op, opts } = parseArgs(process.argv.slice(2));
  if (!op) die("Usage: openclaw-cron-rpc.mjs <status|list|runs|add|remove-matching> [--key value ...]", 2);
  const rpc = new GatewayRpc();
  await rpc.ready();
  let result;
  if (op === "status") result = await rpc.request("cron.status", {});
  else if (op === "list") result = await rpc.request("cron.list", { includeDisabled: true });
  else if (op === "runs") result = await rpc.request("cron.runs", { limit: Number(opts.limit || 20) });
  else if (op === "add") {
    const name = String(opts.name || "").trim();
    const every = String(opts.every || "").trim();
    const message = String(opts.message || "").trim();
    if (!name || !every || !message) die("add requires --name, --every, and --message", 2);
    result = await rpc.request("cron.add", {
      name,
      enabled: true,
      agentId: String(opts.agent || "main"),
      schedule: { kind: "every", everyMs: parseDurationMs(every) },
      sessionTarget: "isolated",
      wakeMode: "now",
      payload: { kind: "agentTurn", message, timeoutSeconds: Number(opts.timeoutSeconds || 900) },
      delivery: { mode: "none" },
    });
  } else if (op === "remove-matching") {
    const selector = String(opts.name || "watchtower-");
    const listed = await rpc.request("cron.list", { includeDisabled: true });
    const jobs = Array.isArray(listed?.jobs) ? listed.jobs : [];
    const matches = jobs.filter((job) => selector === "watchtower-" ? String(job.name || "").startsWith("watchtower-") : String(job.name || "") === selector);
    const removed = [];
    for (const job of matches) {
      if (!job.id) continue;
      await rpc.request("cron.remove", { id: job.id });
      removed.push({ id: job.id, name: job.name });
    }
    result = { removed };
  } else die(`Unknown operation: ${op}`, 2);
  console.log(JSON.stringify(result, null, 2));
  rpc.close();
}

main().catch((err) => die(err?.message || String(err)));
