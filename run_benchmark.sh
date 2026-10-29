#!/bin/bash
# benchmark.rb (orijinal sürücü) — tek koşum, log dosyasına.
cd "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp" || exit 1
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export SELENIT_TARGET_URL="https://www.otoplus.com/ikinci-el-araba"
export SELENIT_SORT_LABEL="Ucuzdan Pahalıya"
export SELENIT_FILTER_MIN=500000
export SELENIT_FILTER_MAX=1500000
export BENCH_MAX_STEPS="${BENCH_MAX_STEPS:-6}"
pkill -f "chrome-profile-" 2>/dev/null
sleep 1
ruby benchmark.rb filtre2 > /tmp/benchrun.log 2>&1
echo "EXITCODE=$?" >> /tmp/benchrun.log
