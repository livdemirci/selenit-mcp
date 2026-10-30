#!/bin/bash
# Tam kıyas koşusu — kendi süreç grubunda, oturum kapanınca ölmez.
# Kullanım: ./run_kiyas.sh            (gemma-4-e4b, 1 koşum, 5 site)
#           MODEL=minicpm5-2b ./run_kiyas.sh
cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export BENCH_MODEL="${MODEL:-google/gemma-4-e4b}"
export KOSUM="${KOSUM:-1}"
export BENCH_MAX_STEPS="${BENCH_MAX_STEPS:-16}"
export PAUSE="${PAUSE:-6}"
mkdir -p artifacts
LOG="artifacts/kiyas-$(date +%Y%m%d-%H%M).log"
ruby kiyas.rb > "$LOG" 2>&1
echo "EXIT=$? LOG=$LOG" >> "$LOG"
tail -40 "$LOG"
