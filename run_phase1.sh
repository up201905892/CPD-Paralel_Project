#!/usr/bin/env bash
# =============================================================================
#  run_phase1.sh — Fase 1: Benchmark single-core automatizado
# =============================================================================
#
#  C++  — V1 (naïve) e V2 (line):
#           n = 1024, 1536, 2048, 2560, 3072          (step 512)
#           n = 4096, 6144, 8192, 10240               (step 2048, só V2)
#
#  Java — V1 (naïve) e V2 (line):
#           n = 1024, 1536, 2048, 2560, 3072          (step 512)
#
#  Saída: results_phase1_cpp.csv  e  results_phase1_java.csv
#
#  NOTA: V1 para n ≥ 4096 pode demorar horas (stride-n → muitos cache misses).
#        Para testar V1 em tamanhos grandes, altere VERSIONS_LARGE para (1 2).
# =============================================================================

set -euo pipefail

# ── Configuração ──────────────────────────────────────────────────────────────
CPP_SRC="mult.cpp"
CPP_BIN="multC"
JAVA_SRC="mult.java"
JAVA_CLASS="MatMult"
CPP_CSV="results_phase1_cpp.csv"
JAVA_CSV="results_phase1_java.csv"

VERSIONS_SMALL=(1 2)   # V1 e V2 para tamanhos pequenos (ambas linguagens)
VERSIONS_LARGE=(2)     # só V2 para tamanhos grandes em C++ (V1 seria impraticável)

PERF_EVENTS="L1-dcache-load-misses,cache-misses"
PERF_TMP=$(mktemp /tmp/perf_out.XXXXXX)

# Verificar se perf está disponível
PERF_OK=false
if command -v perf &>/dev/null; then
    PERF_OK=true
    echo "  [perf] disponível — a medir cache misses com: perf stat -e ${PERF_EVENTS}"
else
    echo "  [perf] não encontrado — colunas de cache misses ficarão vazias."
    echo "         Instalar: sudo apt install linux-tools-common linux-tools-generic"
fi

# ── 1. Compilar ───────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║        Fase 1 — Compilação                  ║"
echo "╚══════════════════════════════════════════════╝"

echo -n "  [C++]  g++ -O2 ... "
g++ -O2 -o "$CPP_BIN" "$CPP_SRC"
echo "OK  →  ./$CPP_BIN"

JAVA_OK=false
if command -v javac &> /dev/null; then
    echo -n "  [Java] javac    ... "
    javac "$JAVA_SRC"
    echo "OK  →  ${JAVA_CLASS}.class"
    JAVA_OK=true
else
    echo "  [Java] javac não encontrado — a ignorar benchmarks Java."
    echo "         Instalar: sudo apt install default-jdk"
fi

# ── 2. Ranges de tamanhos ─────────────────────────────────────────────────────
SIZES_SMALL=()
for n in $(seq 1024 512 3072); do SIZES_SMALL+=("$n"); done

SIZES_LARGE=()
for n in $(seq 4096 2048 10240); do SIZES_LARGE+=("$n"); done

# ── 3. Inicializar CSV ────────────────────────────────────────────────────────
HEADER="version,size_n,time_s,gflops,l1_dcache_load_misses,cache_misses"
echo "$HEADER" > "$CPP_CSV"
echo "$HEADER" > "$JAVA_CSV"

# ── 4. Funções auxiliares ─────────────────────────────────────────────────────

# Extrai um contador de cache do output do perf stat (lida com separadores de milhar)
parse_perf() {
    local output="$1" event="$2"
    echo "$output" | grep "${event}" | head -1 \
        | awk '{gsub(/[,.]/, "", $1); print ($1+0 > 0) ? $1+0 : 0}'
}

# Executa o binário C++ e guarda o resultado no CSV
run_cpp() {
    local ver="$1" n="$2"
    printf "  [C++  V%d  n=%6d]  " "$ver" "$n"
    local line l1_miss llc_miss extra
    if [ "$PERF_OK" = true ]; then
        # perf stat escreve para stderr; redirecionamos stderr→pipe e stdout→ficheiro temp
        local perf_out
        perf_out=$(perf stat -e "$PERF_EVENTS" "./$CPP_BIN" "$ver" "$n" 2>&1 >"$PERF_TMP")
        line=$(cat "$PERF_TMP")
        l1_miss=$(parse_perf "$perf_out" "L1-dcache-load-misses")
        llc_miss=$(parse_perf "$perf_out" "cache-misses")
        extra=",${l1_miss},${llc_miss}"
    else
        line=$("./$CPP_BIN" "$ver" "$n" 2>/dev/null)
        extra=",,"
    fi
    echo "${line}${extra}" >> "$CPP_CSV"
    local gf; gf=$(echo "$line" | awk -F',' '{printf "%.4f", $4}')
    if [ "$PERF_OK" = true ]; then
        echo "${gf} GFlop/s | L1-miss=${l1_miss} LLC-miss=${llc_miss}"
    else
        echo "${gf} GFlop/s"
    fi
}

# Executa a JVM com warmup (n=256) antes da medição real
# O warmup força a compilação JIT das funções antes do teste a dimensão real
run_java() {
    local ver="$1" n="$2"
    printf "  [Java V%d  n=%6d]  " "$ver" "$n"
    # Warmup: corre uma vez com n=256 para activar o JIT compiler
    java -Xmx8g "$JAVA_CLASS" "$ver" 256 > /dev/null 2>&1 || true
    local line l1_miss llc_miss extra
    if [ "$PERF_OK" = true ]; then
        local perf_out
        perf_out=$(perf stat -e "$PERF_EVENTS" java -Xmx8g "$JAVA_CLASS" "$ver" "$n" 2>&1 >"$PERF_TMP")
        line=$(cat "$PERF_TMP")
        l1_miss=$(parse_perf "$perf_out" "L1-dcache-load-misses")
        llc_miss=$(parse_perf "$perf_out" "cache-misses")
        extra=",${l1_miss},${llc_miss}"
    else
        line=$(java -Xmx8g "$JAVA_CLASS" "$ver" "$n" 2>/dev/null)
        extra=",,"
    fi
    echo "${line}${extra}" >> "$JAVA_CSV"
    local gf; gf=$(echo "$line" | awk -F',' '{printf "%.4f", $4}')
    if [ "$PERF_OK" = true ]; then
        echo "${gf} GFlop/s | L1-miss=${l1_miss} LLC-miss=${llc_miss}"
    else
        echo "${gf} GFlop/s"
    fi
}

# ── 5. C++ — tamanhos pequenos: V1 + V2 ──────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  C++ — Tamanhos pequenos (1024→3072, s=512) ║"
echo "╚══════════════════════════════════════════════╝"
for n in "${SIZES_SMALL[@]}"; do
    for v in "${VERSIONS_SMALL[@]}"; do
        run_cpp "$v" "$n"
    done
done

# ── 6. C++ — tamanhos grandes: só V2 ─────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  C++ — Tamanhos grandes (4096→10240,s=2048) ║"
echo "╚══════════════════════════════════════════════╝"
for n in "${SIZES_LARGE[@]}"; do
    for v in "${VERSIONS_LARGE[@]}"; do
        run_cpp "$v" "$n"
    done
done

# ── 7. Java — tamanhos pequenos: V1 + V2 ─────────────────────────────────────
if [ "$JAVA_OK" = true ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Java — Tamanhos pequenos (1024→3072,s=512) ║"
    echo "╚══════════════════════════════════════════════╝"
    for n in "${SIZES_SMALL[@]}"; do
        for v in "${VERSIONS_SMALL[@]}"; do
            run_java "$v" "$n"
        done
    done
else
    echo ""
    echo "  [Java] Benchmarks ignorados (javac não disponível)."
    echo "         Instalar com: sudo apt install default-jdk"
fi

# ── 8. Sumário ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Fase 1 concluída!                          ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  C++:  %-36s║\n" "$CPP_CSV"
printf "║  Java: %-36s║\n" "$JAVA_CSV"
echo "╚══════════════════════════════════════════════╝"

# Limpeza
rm -f "$PERF_TMP"
