#!/usr/bin/env bash
# selenit-mcp tek komut kurulum (macOS/Linux)
#   curl -fsSL https://raw.githubusercontent.com/livdemirci/selenit-mcp/main/install.sh | bash
#
# Yaptıkları: Ruby >= 3.2 kontrol/kurulum, selenium-webdriver gem, Chrome kontrol/kurulum,
# LM Studio config kaydı. Yalnızca eksikleri kurar; mevcut kurulumlara dokunmaz.
set -euo pipefail

PORT="${BROWSER_MCP_PORT:-19419}"
NAME="${SELENIT_NAME:-selenit-browser}"
TARGET="${1:-lmstudio}"

say()  { printf '\033[1m[selenit]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[selenit]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[selenit]\033[0m %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"

# 1) Ruby
if ! command -v ruby >/dev/null 2>&1; then
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    say "Ruby yok; brew install ruby çalıştırılıyor…"
    brew install ruby
    export PATH="$(brew --prefix)/opt/ruby/bin:$PATH"
  else
    die "Ruby >= 3.2 gerekli. macOS: brew install ruby | rbenv install 3.4"
  fi
fi
RUBY_VER="$(ruby -e 'print RUBY_VERSION')"
say "Ruby $RUBY_VER bulundu."

# 2) selenium-webdriver
if ! ruby -e "require 'selenium-webdriver'" >/dev/null 2>&1; then
  say "selenium-webdriver gem kuruluyor…"
  gem install selenium-webdriver --no-document || die "gem kurulamadı (rbenv/izin sorunu olabilir)."
fi
say "selenium-webdriver hazır."

# 3) Chrome
CHROME_FOUND=0
for p in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         /usr/bin/google-chrome /usr/bin/google-chrome-stable /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$p" ] && CHROME_FOUND=1 && break
done
if [ "$CHROME_FOUND" -eq 0 ]; then
  if [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    say "Chrome yok; brew install --cask google-chrome çalıştırılıyor…"
    brew install --cask google-chrome || warn "Chrome kurulamadı; elle kurun."
  else
    warn "Google Chrome bulunamadı; kurmadan tarayıcı açılamaz."
  fi
else
  say "Chrome bulundu."
fi

# 4) config + doğrulama (npx paketin kendi setup'ı)
say "LM Studio config'i yazılıyor ($TARGET, port $PORT)…"
npx -y selenit-mcp setup "$TARGET" --port "$PORT" --name "$NAME" --install
say "Bitti. LM Studio'da Integrations'ı kapat-aç (veya uygulamayı yeniden başlat)."
