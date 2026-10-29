#!/bin/bash
cd "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp"
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export BENCH_MAX_STEPS="${BENCH_MAX_STEPS:-16}"
pkill -f "chrome-profile-" 2>/dev/null
sleep 1

hedef="${1:-otoplus}"
case "$hedef" in
  otoplus)
    export SELENIT_TARGET_URL="https://www.otoplus.com/ikinci-el-araba"
    export SELENIT_FILTER_MIN=500000 SELENIT_FILTER_MAX=1500000
    export SELENIT_SORT_LABEL="Ucuzdan Pahalıya"
    ;;
  arabam)
    export SELENIT_TARGET_URL="https://www.arabam.com/ikinci-el/otomobil"
    export SELENIT_FILTER_MIN=500000 SELENIT_FILTER_MAX=1500000
    export SELENIT_SORT_LABEL="Fiyat - Ucuzdan Pahalıya"
    ;;
esac

ruby benchmark.rb filtre2 > "/tmp/filtre2_${hedef}.log" 2>&1
echo "EXITCODE=$?" >> "/tmp/filtre2_${hedef}.log"
