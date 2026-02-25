#!/bin/bash
# =============================================================================
# run_benchmarks.sh — Benchmark automático de multiplicação de matrizes
#
# Compila mult.cpp com -O2 e executa todos os cenários exigidos:
#   Parte 1: OnMult + OnMultLine  para n = 1024..3072  (passo 512)
#   Parte 2: OnMultLine + OnMultBlock para n = 4096..10240 (passo 2048)
#            OnMultBlock testado com bkSize = 128, 256, 512
#
# Output: results_<timestamp>.csv  com colunas:
#   method, n, block_size, time_s, gflops
#
# Uso:
#   chmod +x run_benchmarks.sh
#   ./run_benchmarks.sh
# =============================================================================

set -euo pipefail   # aborta em erros, variáveis não definidas, pipe failures

# --------------------------------------------------------------------------- #
#  Configuração                                                               #
# --------------------------------------------------------------------------- #

SOURCE="mult.cpp"
BINARY="./mult_bench"                          # binário separado do interativo
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CSV="results_${TIMESTAMP}.csv"
LOG="benchmark_${TIMESTAMP}.log"

# Cores de terminal para legibilidade (desativa se não for tty)
if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; NC=''
fi

# --------------------------------------------------------------------------- #
#  Compilação                                                                 #
# --------------------------------------------------------------------------- #

echo -e "${YELLOW}=== Compilando ${SOURCE} com -O2 ===${NC}"

if ! g++ -O2 -o "$BINARY" "$SOURCE" 2>&1; then
    echo -e "${RED}ERRO: Falha na compilação. Verifica o código-fonte.${NC}"
    exit 1
fi

echo -e "${GREEN}Compilação bem-sucedida → ${BINARY}${NC}"
echo ""

# --------------------------------------------------------------------------- #
#  Cabeçalho do CSV                                                           #
# --------------------------------------------------------------------------- #

echo "method,n,block_size,time_s,gflops" > "$CSV"

# --------------------------------------------------------------------------- #
#  Função: executa um único teste e faz parse do output                       #
# --------------------------------------------------------------------------- #
#  Argumentos:
#    $1  method     — nome para o CSV (OnMult | OnMultLine | OnMultBlock)
#    $2  op         — opção do menu (1 | 2 | 3)
#    $3  n          — dimensão da matriz
#    $4  block_size — tamanho do bloco (ignorado se op != 3; escreve "-" no CSV)
# --------------------------------------------------------------------------- #

run_test() {
    local method="$1"
    local op="$2"
    local n="$3"
    local block="${4:--}"     # default "-" se não fornecido

    # Constrói a sequência de inputs para o menu interativo:
    #   opção → dimensão → (block size, se op=3) → 0 (sair)
    if [ "$op" -eq 3 ]; then
        input=$(printf "%s\n%s\n%s\n0\n" "$op" "$n" "$block")
    else
        input=$(printf "%s\n%s\n0\n" "$op" "$n")
    fi

    # Executa o binário com os inputs via stdin; captura stdout+stderr
    local raw_output
    if ! raw_output=$(echo "$input" | "$BINARY" 2>&1); then
        echo -e "  ${RED}ERRO na execução (op=$op, n=$n, block=$block)${NC}" | tee -a "$LOG"
        echo "${method},${n},${block},ERROR,ERROR" >> "$CSV"
        return
    fi

    # Extrai "Time: X.XXX seconds"  → campo 2
    local time_val
    time_val=$(echo "$raw_output" | grep "Time:" | awk '{print $2}')

    # Extrai "Performance: X.XXX GFlop/s" → campo 2
    local gflops_val
    gflops_val=$(echo "$raw_output" | grep "Performance:" | awk '{print $2}')

    # Guarda raw output no log para auditoria
    echo "--- ${method} n=${n} block=${block} ---" >> "$LOG"
    echo "$raw_output"                              >> "$LOG"
    echo ""                                         >> "$LOG"

    # Valida que conseguimos extrair os valores
    if [ -z "$time_val" ] || [ -z "$gflops_val" ]; then
        echo -e "  ${RED}AVISO: parse falhou (op=$op, n=$n, block=$block)${NC}"
        echo "${method},${n},${block},PARSE_ERROR,PARSE_ERROR" >> "$CSV"
        return
    fi

    # Escreve linha no CSV
    echo "${method},${n},${block},${time_val},${gflops_val}" >> "$CSV"

    # Imprime progresso no terminal
    printf "  %-14s  n=%-6d  block=%-4s  →  %7s s   %s GFlop/s\n" \
           "$method" "$n" "$block" "$time_val" "$gflops_val"
}

# --------------------------------------------------------------------------- #
#  PARTE 1 — n = 1024..3072, passo 512                                       #
#  Métodos: OnMult (op=1) e OnMultLine (op=2)                                #
# --------------------------------------------------------------------------- #

echo -e "${YELLOW}=== PARTE 1: OnMult & OnMultLine (n = 1024..3072, step 512) ===${NC}"

SIZES_P1=(1024 1536 2048 2560 3072)

for n in "${SIZES_P1[@]}"; do
    run_test "OnMult"     1 "$n"
    run_test "OnMultLine" 2 "$n"
done

echo ""

# --------------------------------------------------------------------------- #
#  PARTE 2 — n = 4096..10240, passo 2048                                     #
#  Métodos: OnMultLine (op=2) e OnMultBlock (op=3) com bkSize 128/256/512    #
# --------------------------------------------------------------------------- #

echo -e "${YELLOW}=== PARTE 2: OnMultLine & OnMultBlock (n = 4096..10240, step 2048) ===${NC}"

SIZES_P2=(4096 6144 8192 10240)
BLOCK_SIZES=(128 256 512)

for n in "${SIZES_P2[@]}"; do
    run_test "OnMultLine" 2 "$n"
    for bk in "${BLOCK_SIZES[@]}"; do
        run_test "OnMultBlock" 3 "$n" "$bk"
    done
done

echo ""

# --------------------------------------------------------------------------- #
#  Resumo final                                                               #
# --------------------------------------------------------------------------- #

echo -e "${GREEN}=== Benchmark concluído ===${NC}"
echo -e "  CSV  → ${CSV}"
echo -e "  Log  → ${LOG}"
echo ""

# Imprime o CSV formatado como tabela no terminal para revisão rápida
echo -e "${YELLOW}--- Resultados (CSV) ---${NC}"
column -t -s ',' "$CSV"

# Limpeza do binário temporário
rm -f "$BINARY"
