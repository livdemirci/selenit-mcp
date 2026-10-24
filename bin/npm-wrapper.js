#!/usr/bin/env node
"use strict";
// selenit-mcp npm wrapper: "npx selenit-mcp" MCP sunucusunu armağan eder.
// "npx selenit-mcp setup lmstudio --install" tek komut kurulum yapar:
// ruby + gem + Chrome kontrolü/kurulumu ve istemci config'ine kayıt.
// "npx selenit-mcp doctor" yalnızca durumu raporlar.
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PKG_DIR = path.join(__dirname, "..");
const SERVER = path.join(PKG_DIR, "server.rb");
const ruby = process.env.SLENIT_RUBY || "ruby";
const isMac = process.platform === "darwin";

const argv = process.argv.slice(2);
if (argv[0] === "setup") {
  setup(argv.slice(1));
} else if (argv[0] === "doctor") {
  doctor(argv.slice(1));
} else if (argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") {
  help();
} else {
  serve();
}

// ---------------------------------------------------------------- sunucu ----

function serve() {
  const rubyPath = resolveRuby();
  if (!rubyPath) {
    console.error("[selenit-mcp] Ruby bulunamadı (>= 3.2 gerekir).");
    console.error("  - macOS: brew install ruby   |  rbenv: rbenv install 3.4");
    console.error("  - Ruby farklı yerdeyse: SLENIT_RUBY=/tam/yol/ruby npx selenit-mcp");
    process.exit(1);
  }

  const gemCheck = spawnSync(rubyPath, ["-e", "require 'selenium-webdriver'"], {
    stdio: "ignore",
    env: process.env,
  });
  if (gemCheck.status !== 0) {
    console.error("[selenit-mcp] 'selenium-webdriver' gem'i eksik. Tek komut kurulum:");
    console.error("  npx -y selenit-mcp setup lmstudio --install");
    console.error("  (ya da elle: gem install selenium-webdriver)");
    process.exit(1);
  }

  const child = spawn(rubyPath, [SERVER], {
    stdio: "inherit",
    env: process.env,
  });

  const forward = (sig) => {
    try {
      child.kill(sig);
    } catch {}
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
}

// ---------------------------------------------------------------- setup ----

function setup(args) {
  const o = parseSetupOptions(args);
  if (o.help) return help();

  const steps = [];
  const fail = (msg, hint) => {
    steps.push(`✗ ${msg}`);
    if (hint) steps.push(`   → ${hint}`);
    printSteps(steps);
    process.exit(1);
  };

  // 1) Ruby
  let rubyPath = resolveRuby();
  if (!rubyPath && o.install) {
    console.log("[selenit-mcp] Ruby yok; kuruluyor (brew install ruby)…");
    const r = spawnSync("brew", ["install", "ruby"], { stdio: "inherit" });
    if (r.status === 0) rubyPath = resolveRuby(true);
  }
  if (!rubyPath) {
    fail(
      "Ruby bulunamadı (>= 3.2 gerekir).",
      isMac
        ? "brew install ruby   (veya: rbenv install 3.4)  → sonra tekrar çalıştırın"
        : "paket yöneticinizle Ruby >= 3.2 kurun → sonra tekrar çalıştırın"
    );
  }
  steps.push(`✓ Ruby: ${rubyPath}`);

  // 2) selenium-webdriver gem
  let gemOk = hasGem(rubyPath);
  if (!gemOk && o.install) {
    console.log("[selenit-mcp] 'selenium-webdriver' gem'i kuruluyor…");
    const r = spawnSync(rubyPath, ["-S", "gem", "install", "selenium-webdriver", "--no-document"], {
      stdio: "inherit",
      env: process.env,
    });
    gemOk = r.status === 0 && hasGem(rubyPath);
  }
  if (!gemOk) {
    fail(
      "'selenium-webdriver' gem'i eksik.",
      `npx -y selenit-mcp setup lmstudio --install   (ya da: ${rubyPath} -S gem install selenium-webdriver)`
    );
  }
  steps.push("✓ selenium-webdriver gem");

  // 3) Chrome
  let chromePath = detectChrome();
  if (!chromePath && o.installChrome) {
    console.log("[selenit-mcp] Google Chrome kuruluyor (brew install --cask google-chrome)…");
    const r = spawnSync("brew", ["install", "--cask", "google-chrome"], { stdio: "inherit" });
    if (r.status === 0) chromePath = detectChrome();
  }
  if (chromePath) {
    steps.push(`✓ Chrome: ${chromePath}`);
  } else {
    steps.push("! Chrome bulunamadı — sunucu tarayıcı açamaz.");
    steps.push(
      isMac
        ? "   → brew install --cask google-chrome   (veya --install-chrome bayrağı)"
        : "   → Google Chrome kurun (veya CHROME_PATH ile yolu verin)"
    );
  }

  // 4) config
  const entry = {
    command: rubyPath,
    args: [SERVER],
    cwd: PKG_DIR,
    env: {
      BROWSER_MCP_PORT: o.port,
      BROWSER_MCP_MAX_ELEMENTS: o.maxElements,
    },
  };
  const json = JSON.stringify({ mcpServers: { [o.name]: entry } }, null, 2);

  if (o.print || o.target === "print") {
    console.log(json);
    return;
  }

  const file = o.file || defaultConfigPath(o.target);
  if (!file) {
    fail(`Bilinmeyen hedef: ${o.target}.`, "Desteklenen: lmstudio, claude, print");
  }

  let doc = {};
  if (fs.existsSync(file)) {
    const raw = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
    if (raw.trim()) {
      try {
        doc = JSON.parse(raw);
      } catch (err) {
        fail(`${file} geçerli JSON değil; elle düzenleyin.`, `Hata: ${err.message}  |  JSON için: npx selenit-mcp setup print`);
      }
    }
    if (o.dryRun) {
      console.log(`[selenit-mcp] (deneme) ${file} içine yazılacak:\n`);
      console.log(JSON.stringify({ [o.name]: entry }, null, 2));
      return;
    }
    const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
    fs.copyFileSync(file, `${file}.backup-${stamp}`);
  }

  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
    fail(`${file} bir JSON nesnesi değil; elle düzenleyin.`);
  }
  if (typeof doc.mcpServers !== "object" || doc.mcpServers === null || Array.isArray(doc.mcpServers)) {
    doc.mcpServers = {};
  }
  doc.mcpServers[o.name] = entry;

  if (o.dryRun) {
    console.log(`[selenit-mcp] (deneme) ${file} içine yazılacak:\n`);
    console.log(JSON.stringify({ [o.name]: entry }, null, 2));
    return;
  }

  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(doc, null, 2) + "\n", "utf8");

  steps.push(`✓ config: ${o.name} -> ${file}  (port ${o.port})`);
  if (PKG_DIR.includes(`${path.sep}_npx${path.sep}`)) {
    steps.push("! Bu yol npx önbelleğinde; kalıcı kurulum: npm i -g selenit-mcp && selenit-mcp setup lmstudio");
  }
  steps.push("→ LM Studio: Integrations'ı kapat-aç veya uygulamayı yeniden başlat.");
  printSteps(steps);
}

function printSteps(steps) {
  console.log("");
  console.log(steps.join("\n"));
  console.log("");
}

// --------------------------------------------------------------- doctor ----

function doctor(args) {
  const o = parseSetupOptions(args);
  const rows = [];
  const add = (ok, label, detail) => rows.push(`${ok ? "✓" : "✗"} ${label}${detail ? `: ${detail}` : ""}`);

  add(true, "Node", `${process.version} (${process.platform}/${process.arch})`);

  const rubyPath = resolveRuby();
  add(Boolean(rubyPath), "Ruby", rubyPath || "bulunamadı (>= 3.2 gerekir)");
  if (rubyPath) {
    const ver = spawnSync(rubyPath, ["-e", "print RUBY_VERSION"], { encoding: "utf8" }).stdout || "";
    add(Number(ver.split(".")[0]) >= 3 && Number(ver.split(".")[1]) >= 2, "Ruby sürümü", ver.trim());
    add(hasGem(rubyPath), "selenium-webdriver", hasGem(rubyPath) ? "kurulu" : "eksik → npx selenit-mcp setup --install");
  }

  const chromePath = detectChrome();
  add(Boolean(chromePath), "Chrome", chromePath || "bulunamadı");

  const file = o.file || defaultConfigPath(o.target);
  let configured = false;
  if (file && fs.existsSync(file)) {
    try {
      const doc = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
      configured = Boolean(doc.mcpServers && doc.mcpServers[o.name]);
    } catch {}
  }
  add(configured, "MCP config", `${file}${configured ? " (kayıtlı)" : " (kayıt yok)"}`);

  const port = o.port;
  const busy = portInUse(port);
  add(!busy, `port ${port}`, busy ? "dolu (başka bir Chrome/MCP kullanıyor olabilir)" : "boş");

  console.log("\nselenit-mcp doctor\n");
  console.log(rows.join("\n"));
  console.log("\nKurulum: npx -y selenit-mcp setup lmstudio --install\n");
  process.exit(rows.some((r) => r.startsWith("✗")) ? 1 : 0);
}

// -------------------------------------------------------------- yardımcı ----

function parseSetupOptions(args) {
  const o = {
    target: "lmstudio",
    port: "19419",
    maxElements: "40",
    name: "selenit-browser",
    file: null,
    dryRun: false,
    print: false,
    help: false,
    install: false,
    installChrome: false,
  };
  const positional = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--port") o.port = args[++i];
    else if (a === "--max-elements") o.maxElements = args[++i];
    else if (a === "--name") o.name = args[++i];
    else if (a === "--file") o.file = args[++i];
    else if (a === "--dry-run") o.dryRun = true;
    else if (a === "--print") o.print = true;
    else if (a === "--help" || a === "-h") o.help = true;
    else if (a === "--install" || a === "-y") o.install = true;
    else if (a === "--install-chrome") o.installChrome = true;
    else if (a === "--no-install") o.install = false;
    else positional.push(a);
  }
  if (positional[0]) o.target = positional[0];
  return o;
}

function resolveRuby(afterInstall = false) {
  const candidates = [ruby];
  if (afterInstall) {
    candidates.push(
      "/opt/homebrew/opt/ruby/bin/ruby",
      "/usr/local/opt/ruby/bin/ruby",
      "/opt/homebrew/bin/ruby"
    );
  }
  for (const cand of candidates) {
    const out = spawnSync(cand, ["-e", "print RbConfig.ruby"], { encoding: "utf8", env: process.env });
    if (out.status === 0 && out.stdout && out.stdout.trim()) return out.stdout.trim();
  }
  return null;
}

function hasGem(rubyPath) {
  const out = spawnSync(rubyPath, ["-e", "require 'selenium-webdriver'"], {
    stdio: "ignore",
    env: process.env,
  });
  return out.status === 0;
}

function detectChrome() {
  if (process.env.CHROME_PATH && fs.existsSync(process.env.CHROME_PATH)) return process.env.CHROME_PATH;
  const candidates = isMac
    ? [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        path.join(os.homedir(), "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
      ]
    : ["/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

function portInUse(port) {
  const out = spawnSync(isMac ? "lsof" : "ss", isMac ? ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN"] : ["-ltn"], {
    encoding: "utf8",
  });
  return out.status === 0 && String(out.stdout || "").trim().length > 0;
}

function defaultConfigPath(target) {
  const home = os.homedir();
  if (target === "lmstudio") return path.join(home, ".lmstudio", "mcp.json");
  if (target === "claude") {
    if (process.platform === "darwin") {
      return path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json");
    }
    if (process.platform === "win32") {
      return path.join(process.env.APPDATA || home, "Claude", "claude_desktop_config.json");
    }
    return path.join(home, ".config", "Claude", "claude_desktop_config.json");
  }
  return null;
}

function help() {
  console.log(`selenit-mcp — Selenium tabanlı hafif tarayıcı MCP sunucusu

Kullanım:
  npx selenit-mcp                                  stdio MCP sunucusunu başlat
  npx selenit-mcp setup lmstudio --install         TEK KOMUT: ruby+gem+Chrome kontrol/kurulum + config
  npx selenit-mcp setup lmstudio                   yalnızca config yaz (eksikleri raporlar)
  npx selenit-mcp setup claude                     Claude Desktop config'ine ekle
  npx selenit-mcp setup print                      yalnızca JSON bas
  npx selenit-mcp doctor                           ruby/gem/Chrome/config/port durumu

Seçenekler:
  --install, -y         eksik ruby/gem'i kurmayı dene (brew/gem)
  --install-chrome      Chrome yoksa "brew install --cask google-chrome" çalıştır
  --port <n>            CDP portu (varsayılan 19419)
  --max-elements <n>    dökümde en fazla öğe (varsayılan 40)
  --name <ad>           mcpServers anahtarı (varsayılan selenit-browser)
  --file <yol>          config dosyasını değiştir (test için)
  --dry-run             yazmadan göster
  --print               yalnızca JSON bas

Ortam:
  SLENIT_RUBY           kullanılacak ruby yolu (varsayılan: PATH'teki ruby)
  CHROME_PATH           Chrome binary yolu (algılama başarısızsa)
`);
}
