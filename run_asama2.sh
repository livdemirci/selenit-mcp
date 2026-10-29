#!/bin/bash
# Aşama-2 koşumu: selenit-mcp + gemma-4-e4b, filtre2 görevi, N tekrar.
#   ./run_asama2.sh <hedef> <tekrar> [surucu]
#   hedef: otoplus | arabam
#   surucu: cozucu (varsayılan) | benchmark
cd "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp" || exit 1
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

hedef="${1:-otoplus}"
tekrar="${2:-3}"
surucu="${3:-cozucu}"

case "$hedef" in
  otoplus)
    export SELENIT_TARGET_URL="https://www.otoplus.com/ikinci-el-araba"
    export SELENIT_SORT_LABEL="Ucuzdan Pahalıya"
    ;;
  arabam)
    export SELENIT_TARGET_URL="https://www.arabam.com/ikinci-el/otomobil"
    export SELENIT_SORT_LABEL="Fiyat - Ucuzdan Pahalıya"
    ;;
esac
export SELENIT_FILTER_MIN="${SELENIT_FILTER_MIN:-500000}"
export SELENIT_FILTER_MAX="${SELENIT_FILTER_MAX:-1500000}"

pkill -f "chrome-profile-" 2>/dev/null
sleep 1

log="/tmp/asama2_${hedef}_${surucu}.log"
if [ "$surucu" = "benchmark" ]; then
  ruby benchmark.rb filtre2 > "$log" 2>&1
else
  ruby benchmark_cozucu.rb filtre2 "$tekrar" > "$log" 2>&1
fi
echo "EXITCODE=$?" >> "$log"
