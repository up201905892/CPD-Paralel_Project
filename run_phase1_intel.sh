#!/usr/bin/env bash
# =============================================================================
#  run_phase1_intel.sh — Fase 1: Benchmark single-core automatizado (Intel)
# =============================================================================
#
#  C++  — V1 (naïve) e V2 (line):
#           n = 1024, 1536, 2048, 2560, 3072          (step 512)
#           n = 4096, 6144, 8192, 10240               (step 2048, só V2)
#
#  C#   — V1 (naïve) e V2 (line):
#           n = 1024, 1536, 2048, 2560, 3072          (step 512)
#
#  Saída: results_phase1_cpp.csv  e  results_phase1_cs.csv
#
#  NOTA: V1 para n ≥ 4096 pode demorar horas (stride-n → muitos cache misses).
#        Para testar V1 em tamanhos grandes, altere VERSIONS_LARGE para (1 2).
# =============================================================================

set -euo pipefail

# ── Configuração ──────────────────────────────────────────────────────────────
CPP_SRC="mult.cpp"
CPP_BIN="multC"
CS_PROJ="mult.csproj"
CS_BIN="bin_cs/multCS.dll"
CPP_CSV="results_phase1_cpp.csv"
CS_CSV="results_phase1_cs.csv"

VERSIONS_SMALL=(1 2)   # V1 e V2 para tamanhos pequenos (ambas linguagens)
VERSIONS_LARGE=(2)     # só V2 para tamanhos grandes em C++ (V1 seria impraticável)

# Evento L2 para CPUs Intel
L2_EVENT="l2_rqsts.miss"
PERF_EVENTS="L1-dcache-load-misses,${L2_EVENT},LLC-load-misses"
PERF_TMP=$(mktemp /tmp/perf_out.XXXXXX)

# ── Verificar perf ────────────────────────────────────────────────────────────
PERF_OK=false
if command -v perf &>/dev/null; then
    PERF_OK=true

    # Avisar se o kernel bloqueia contadores hardware (paranoid > 1 → valores 0)
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "?")
    if [[ "$paranoid" =~ ^[0-9]+$ ]] && [ "$paranoid" -gt 1 ]; then
        echo "  [perf] AVISO: perf_event_paranoid=${paranoid} — contadores hw BLOQUEADOS (L1/L2/LLC serão 0)."
        echo "         Corrigir: sudo sysctl kernel.perf_event_paranoid=1"
    fi

    # Detetar WSL (não suporta hardware PMU por defeito)
    if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
        echo "  [perf] AVISO: WSL detectado — hardware PMU não suportado."
        echo "         Execute em Linux nativo para cache misses reais."
    fi

    # Teste rápido: validar que L1-dcache-load-misses funciona
    _test=$(perf stat -e L1-dcache-load-misses true 2>&1) || true
    if echo "$_test" | grep -qE "<not supported>|not counted|Operation not permitted|sys_perf_event_open|No such event"; then
        echo "  [perf] ERRO: L1-dcache-load-misses indisponível — verifique as permissões acima."
        PERF_OK=false
    else
        echo "  [perf] Hardware PMU OK — eventos: ${PERF_EVENTS}"
    fi
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

CS_OK=false
if command -v dotnet &>/dev/null; then
    echo -n "  [C#]   dotnet build -c Release ... "
    dotnet build -c Release "$CS_PROJ" -o bin_cs > /dev/null 2>&1
    echo "OK  →  ${CS_BIN}"
    CS_OK=true
else
    echo "  [C#]   dotnet não encontrado — a ignorar benchmarks C#."
    echo "         Instalar: https://dotnet.microsoft.com/download"
fi

# ── 2. Ranges de tamanhos ─────────────────────────────────────────────────────
SIZES_SMALL=()
for n in $(seq 1024 512 3072); do SIZES_SMALL+=("$n"); done

SIZES_LARGE=()
for n in $(seq 4096 2048 10240); do SIZES_LARGE+=("$n"); done

# ── 3. Inicializar CSV ────────────────────────────────────────────────────────
HEADER="version,size_n,time_s,gflops,l1_dcache_load_misses,l2_cache_misses,llc_load_misses"
echo "$HEADER" > "$CPP_CSV"
echo "$HEADER" > "$CS_CSV"

# ── 4. Funções auxiliares ─────────────────────────────────────────────────────

# Extrai um contador de cache do output do perf stat (lida com separadores de milhar)
parse_perf() {
    local output="$1" event="$2"
    echo "$output" | grep -F "${event}" | head -1 \
        | awk '{gsub(/[,.]/, "", $1); val=$1+0; print (val>0)?val:0}'
}

# Executa o binário C++ e guarda o resultado no CSV
run_cpp() {
    local ver="$1" n="$2"
    printf "  [C++  V%d  n=%6d]  " "$ver" "$n"
    local line l1_miss l2_miss llc_miss extra
    if [ "$PERF_OK" = true ]; then
        local perf_out
        perf_out=$(perf stat -e "$PERF_EVENTS" "./$CPP_BIN" "$ver" "$n" 2>&1 >"$PERF_TMP") || true
        line=$(cat "$PERF_TMP")
        l1_miss=$(parse_perf "$perf_out" "L1-dcache-load-misses")
        l2_miss=$(parse_perf "$perf_out" "$L2_EVENT")
        llc_miss=$(parse_perf "$perf_out" "LLC-load-misses")
        extra=",${l1_miss},${l2_miss},${llc_miss}"
    else
        line=$("./$CPP_BIN" "$ver" "$n" 2>/dev/null)
        extra=",,,,"
    fi
    echo "${line}${extra}" >> "$CPP_CSV"
    local gf; gf=$(echo "$line" | awk -F',' '{printf "%.4f", $4}')
    if [ "$PERF_OK" = true ]; then
        echo "${gf} GFlop/s | L1-miss=${l1_miss} L2-miss=${l2_miss} LLC-miss=${llc_miss}"
    else
        echo "${gf} GFlop/s"
    fi
}

# Executa o binário C# com warmup (n=256) antes da medição real
run_cs() {
    local ver="$1" n="$2"
    printf "  [C#   V%d  n=%6d]  " "$ver" "$n"
    dotnet "$CS_BIN" "$ver" 256 > /dev/null 2>&1 || true
    local line l1_miss l2_miss llc_miss extra
    if [ "$PERF_OK" = true ]; then
        local perf_out
        perf_out=$(perf stat -e "$PERF_EVENTS" dotnet "$CS_BIN" "$ver" "$n" 2>&1 >"$PERF_TMP") || true
        line=$(cat "$PERF_TMP")
        l1_miss=$(parse_perf "$perf_out" "L1-dcache-load-misses")
        l2_miss=$(parse_perf "$perf_out" "$L2_EVENT")
        llc_miss=$(parse_perf "$perf_out" "LLC-load-misses")
        extra=",${l1_miss},${l2_miss},${llc_miss}"
    else
        line=$(dotnet "$CS_BIN" "$ver" "$n" 2>/dev/null)
        extra=",,,,"
    fi
    echo "${line}${extra}" >> "$CS_CSV"
    local gf; gf=$(echo "$line" | awk -F',' '{printf "%.4f", $4}')
    if [ "$PERF_OK" = true ]; then
        echo "${gf} GFlop/s | L1-miss=${l1_miss} L2-miss=${l2_miss} LLC-miss=${llc_miss}"
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

# ── 7. C# — tamanhos pequenos: V1 + V2 ───────────────────────────────────────
if [ "$CS_OK" = true ]; then
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  C#  — Tamanhos pequenos (1024→3072,s=512)  ║"
    echo "╚══════════════════════════════════════════════╝"
    for n in "${SIZES_SMALL[@]}"; do
        for v in "${VERSIONS_SMALL[@]}"; do
            run_cs "$v" "$n"
        done
    done
else
    echo ""
    echo "  [C#] Benchmarks ignorados (dotnet não disponível)."
    echo "       Instalar: https://dotnet.microsoft.com/download"
fi

# ── 8. Sumário ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Fase 1 concluída!                          ║"
echo "╠══════════════════════════════════════════════╣"
printf "║  C++: %-37s║\n" "$CPP_CSV"
printf "║  C#:  %-37s║\n" "$CS_CSV"
echo "╚══════════════════════════════════════════════╝"

# Limpeza
rm -f "$PERF_TMP"
