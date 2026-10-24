#!/usr/bin/env node
"use strict";
// selenit-mcp npm wrapper: "npx selenit-mcp" MCP sunucusunu armağan eder.
// "npx selenit-mcp setup [lmstudio|claude|print]" ise istemci config'ine
// kendini otomatik ekler (mutlak ruby + paket yolları çözülür).
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const PKG_DIR = path.join(__dirname, "..");
const SERVER = path.join(PKG_DIR, "server.rb");
const ruby = process.env.SLENIT_RUBY || "ruby";

const argv = process.argv.slice(2);
if (argv[0] === "setup") {
  setup(argv.slice(1));
} else if (argv[0] === "--help" || argv[0] === "-h" || argv[0] === "help") {
  help();
} else {
  serve();
}

// ---------------------------------------------------------------- sunucu ----

function serve() {
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

  const child = spawn(ruby, [SERVER], {
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

// ----------------------------------------------------------------- setup ----

function setup(args) {
  const o = parseSetupOptions(args);
  if (o.help) return help();

  const rubyPath = resolveRuby();
  if (!rubyPath) {
    console.error("[selenit-mcp] Ruby bulunamadı. Önce Ruby >= 3.2 kurun (SLENIT_RUBY ile yol verebilirsiniz).");
    process.exit(1);
  }

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
    console.error(`[selenit-mcp] Bilinmeyen hedef: ${o.target}. Desteklenen: lmstudio, claude, print.`);
    process.exit(1);
  }

  let doc = {};
  if (fs.existsSync(file)) {
    const raw = fs.readFileSync(file, "utf8").replace(/^\uFEFF/, "");
    if (raw.trim()) {
      try {
        doc = JSON.parse(raw);
      } catch (err) {
        console.error(`[selenit-mcp] ${file} geçerli JSON değil; elle düzenleyin.`);
        console.error(`  Hata: ${err.message}`);
        console.error("  Elle eklemek için: npx selenit-mcp setup print");
        process.exit(1);
      }
    }
    if (o.dryRun) {
      // yedek yazmadan sadece rapor
    } else {
      const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
      fs.copyFileSync(file, `${file}.backup-${stamp}`);
    }
  }

  if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
    console.error(`[selenit-mcp] ${file} bir JSON nesnesi değil; elle düzenleyin.`);
    process.exit(1);
  }
  if (typeof doc.mcpServers !== "object" || doc.mcpServers === null || Array.isArray(doc.mcpServers)) {
    doc.mcpServers = {};
  }
  doc.mcpServers[o.name] = entry;

  const out = JSON.stringify(doc, null, 2) + "\n";
  if (o.dryRun) {
    console.log(`[selenit-mcp] (deneme) ${file} içine yazılacak:\n`);
    console.log(JSON.stringify({ [o.name]: entry }, null, 2));
    return;
  }

  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, out, "utf8");

  console.log(`[selenit-mcp] ${o.name} -> ${file}`);
  console.log(`  ruby:  ${rubyPath}`);
  console.log(`  sunucu: ${SERVER}`);
  console.log(`  port:  ${o.port}  (profil: artifacts/chrome-profile-${o.port})`);
  if (PKG_DIR.includes(`${path.sep}_npx${path.sep}`)) {
    console.log("");
    console.log("  NOT: Bu yol npx önbelleğine ait; temizlenebilir. Kalıcı kurulum için:");
    console.log("    npm i -g selenit-mcp && selenit-mcp setup lmstudio");
  }
  console.log("");
  console.log("  LM Studio: Integrations'ı kapat-aç veya uygulamayı yeniden başlat.");
}

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
    else positional.push(a);
  }
  if (positional[0]) o.target = positional[0];
  return o;
}

function resolveRuby() {
  const out = spawnSync(ruby, ["-e", "print RbConfig.ruby"], {
    encoding: "utf8",
    env: process.env,
  });
  if (out.status === 0 && out.stdout && out.stdout.trim()) return out.stdout.trim();
  return null;
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
  npx selenit-mcp                      stdio MCP sunucusunu başlat (istemciler bunu çağırır)
  npx selenit-mcp setup lmstudio       ~/.lmstudio/mcp.json'a kendini ekle
  npx selenit-mcp setup claude         Claude Desktop config'ine ekle
  npx selenit-mcp setup print          yalnızca JSON'u bas (elle yapıştırmak için)

Seçenekler:
  --port <n>            CDP portu (varsayılan 19419)
  --max-elements <n>    dökümde en fazla öğe (varsayılan 40)
  --name <ad>           mcpServers altındaki anahtar (varsayılan selenit-browser)
  --file <yol>          config dosyasını geçici olarak değiştir (test için)
  --dry-run             yazmadan ne yazılacağını göster
  --print               yalnızca JSON'u bas

Ortam:
  SLENIT_RUBY           kullanılacak ruby yolu (varsayılan: PATH'teki ruby)
`);
}
