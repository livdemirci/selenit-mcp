#!/bin/bash
# Tek koşum + canlı log. Kullanım: ./run_trace.sh [görev] [port]
cd "/Users/mustafalivdemirci/Documents/Varsayılan Proje/selenit_mcp" || exit 1
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export SELENIT_TARGET_URL="${SELENIT_TARGET_URL:-https://www.otoplus.com/ikinci-el-araba}"
export SELENIT_SORT_LABEL="${SELENIT_SORT_LABEL:-Ucuzdan Pahalıya}"
export SELENIT_FILTER_MIN="${SELENIT_FILTER_MIN:-500000}"
export SELENIT_FILTER_MAX="${SELENIT_FILTER_MAX:-1500000}"
export MAX_STEPS="${MAX_STEPS:-12}"
pkill -f "chrome-profile-" 2>/dev/null
sleep 1
ruby tmp_trace2.rb "${1:-filtre2}" "${2:-19445}" 2>&1 | tee /tmp/trace.log
