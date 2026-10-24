#!/usr/bin/env node
"use strict";
// selenit-mcp npm wrapper: "npx selenit-mcp" MCP sunucusunu armağan eder.
// Ruby kaynakları paketle gelir; bu dosya yalnızca ruby ortamını kontrol eder ve başlatır.
const { spawn, spawnSync } = require("node:child_process");
const path = require("node:path");

const ruby = process.env.SLENIT_RUBY || "ruby";

const rubyCheck = spawnSync(ruby, ["-e", "1"], { stdio: "ignore" });
if (rubyCheck.error || rubyCheck.status !== 0) {
  console.error("[selenit-mcp] Ruby bulunamadı (>= 3.2 gerekir).");
  console.error("  - macOS: brew install ruby   |  rbenv: rbenv install 3.4");
  console.error("  - Ruby farklı yerdeyse: SLENIT_RUBY=/tam/yol/ruby npx selenit-mcp");
  process.exit(1);
}

const gemCheck = spawnSync(ruby, ["-e", "require 'selenium-webdriver'"], {
  stdio: "ignore",
  env: process.env,
});
if (gemCheck.status !== 0) {
  console.error("[selenit-mcp] 'selenium-webdriver' gem'i eksik. Önce şunu çalıştır:");
  console.error("  gem install selenium-webdriver");
  console.error("(istemcinin çalıştırdığı ruby ile AYNI kurulumu hedeflediğinden emin ol; rbenv kullanıyorsanız 'which ruby' ile karşılaştırın.)");
  process.exit(1);
}

const server = path.join(__dirname, "..", "server.rb");
const child = spawn(ruby, [server], {
  stdio: "inherit",
  env: process.env,
});

const forward = (sig) => {
  try {
    child.kill(sig);
  } catch {}
  // Son çare: sinyali görünce kendiliğimizden toparlanmazsak süreçten çık.
  setTimeout(() => process.exit(0), 3000).unref();
};
["SIGINT", "SIGTERM", "SIGHUP"].forEach((s) => process.on(s, () => forward(s)));

child.on("error", (err) => {
  console.error(`[selenit-mcp] ruby başlatılamadı: ${err.message}`);
  process.exit(1);
});
child.on("exit", (code, signal) => {
  process.exit(signal ? 1 : code == null ? 1 : code);
});
