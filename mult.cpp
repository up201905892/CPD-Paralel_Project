// =============================================================================
//  mult.cpp — Multiplicação de Matrizes em C++ (Fase 1: Single-core)
// =============================================================================
//
//  Versão 1 — Naïve     (i, j, k) : acesso strided a B → cache-unfriendly
//  Versão 2 — Line      (i, k, j) : stride-1 em B e C  → cache-friendly
//  Versão 3 — Block     tiling ikj : working set cabe na L2/L3
//
//  Compilar : g++ -O2 -o multC mult.cpp
//
//  Modo interactivo : ./multC
//  Modo batch (CSV) : ./multC <versão> <n> [blocksize]
//      Saída         : versão,n,tempo_s,gflops   (uma linha CSV)
//
//  Métrica: GFlop/s = 2·n³ / (tempo_s × 10⁹)
// =============================================================================

#include <iostream>
#include <iomanip>
#include <cstdlib>
#include <algorithm>
#include <chrono>

using namespace std;
using namespace std::chrono;

// ── Helpers ──────────────────────────────────────────────────────────────────

static inline double gflops(int n, double sec)
{
    return (2.0 * (double)n * (double)n * (double)n) / (sec * 1.0e9);
}

// =============================================================================
//  Versão 1 — Naïve (i, j, k)
// =============================================================================
//  Loop mais interior: temp += pha[i*n+k] * phb[k*n+j]
//    → k varia, j fixo → phb salta n doubles por iteração (stride = n)
//    → para n=1024: salto de 8 KB; hardware prefetcher ineficaz
//    → resultado: misses frequentes na L1 e L2
// =============================================================================
double OnMult(int n, bool verbose)
{
    double *pha = (double *)malloc((size_t)n * n * sizeof(double));
    double *phb = (double *)malloc((size_t)n * n * sizeof(double));
    double *phc = (double *)malloc((size_t)n * n * sizeof(double));

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    // Pre-touch phc para evitar page-faults durante a medição
    // (garante paridade de condições com as versões 2 e 3)
    for (size_t i = 0; i < (size_t)n * n; i++)
        phc[i] = 0.0;

    auto t1 = high_resolution_clock::now();

    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            double temp = 0.0;
            for (int k = 0; k < n; k++)
                temp += pha[i * n + k] * phb[k * n + j]; // stride-n em phb
            phc[i * n + j] = temp;
        }
    }

    double elapsed = duration<double>(high_resolution_clock::now() - t1).count();

    if (verbose) {
        cout << "Result matrix:\n";
        for (int j = 0; j < min(n, 10); j++)
            cout << phc[j] << " ";
        cout << "\n";
    }

    free(pha); free(phb); free(phc);
    return elapsed;
}

// =============================================================================
//  Versão 2 — Line-by-line (i, k, j)
// =============================================================================
//  Inversão dos loops k ↔ j:
//    → loop interior percorre j: phb[k*n+j] e phc[i*n+j] ambos stride-1
//    → pha[i*n+k] içado como escalar → 0 loads no inner loop
//    → cada cache-line de 64 B serve 8 iterações consecutivas de j
//    → misses na L1/L2 reduzidos em ~8× face à versão naïve
// =============================================================================
double OnMultLine(int n, bool verbose)
{
    double *pha = (double *)malloc((size_t)n * n * sizeof(double));
    double *phb = (double *)malloc((size_t)n * n * sizeof(double));
    double *phc = (double *)malloc((size_t)n * n * sizeof(double));

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    // Obrigatório: phc começa a zero para acumulação com +=
    for (size_t i = 0; i < (size_t)n * n; i++)
        phc[i] = 0.0;

    auto t1 = high_resolution_clock::now();

    for (int i = 0; i < n; i++) {
        for (int k = 0; k < n; k++) {
            double a_ik = pha[i * n + k]; // escalar — permanece em registo
            for (int j = 0; j < n; j++)
                phc[i * n + j] += a_ik * phb[k * n + j]; // stride-1
        }
    }

    double elapsed = duration<double>(high_resolution_clock::now() - t1).count();

    if (verbose) {
        cout << "Result matrix:\n";
        for (int j = 0; j < min(n, 10); j++)
            cout << phc[j] << " ";
        cout << "\n";
    }

    free(pha); free(phb); free(phc);
    return elapsed;
}

// =============================================================================
//  Versão 3 — Block/Tiling (ii, kk, jj) com inner (i, k, j)
// =============================================================================
//  Working set activo por iteração de bloco: 3 × bk² × 8 bytes
//    bk=128 → 384 KB  (cabe na L2 típica de 512 KB–1 MB)
//    bk=256 → 1.5 MB  (cabe na L3)
//    bk=512 → 6 MB    (pode exceder L3 em CPUs mais modestos)
//  Mantém o padrão ikj da V2 dentro de cada bloco.
// =============================================================================
double OnMultBlock(int n, int bk, bool verbose)
{
    double *pha = (double *)malloc((size_t)n * n * sizeof(double));
    double *phb = (double *)malloc((size_t)n * n * sizeof(double));
    double *phc = (double *)malloc((size_t)n * n * sizeof(double));

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    for (size_t i = 0; i < (size_t)n * n; i++)
        phc[i] = 0.0;

    auto t1 = high_resolution_clock::now();

    for (int ii = 0; ii < n; ii += bk)
    for (int kk = 0; kk < n; kk += bk)
    for (int jj = 0; jj < n; jj += bk) {
        int i_max = min(ii + bk, n);
        int k_max = min(kk + bk, n);
        int j_max = min(jj + bk, n);

        for (int i = ii; i < i_max; i++)
        for (int k = kk; k < k_max; k++) {
            double a_ik = pha[i * n + k];
            for (int j = jj; j < j_max; j++)
                phc[i * n + j] += a_ik * phb[k * n + j];
        }
    }

    double elapsed = duration<double>(high_resolution_clock::now() - t1).count();

    if (verbose) {
        cout << "Result matrix:\n";
        for (int j = 0; j < min(n, 10); j++)
            cout << phc[j] << " ";
        cout << "\n";
    }

    free(pha); free(phb); free(phc);
    return elapsed;
}

// =============================================================================
//  main
// =============================================================================
//  Modo batch (com argumentos):
//      ./multC <versão> <n> [blocksize]
//      Saída: versão,n,tempo_s,gflops   ← linha CSV directa
//
//  Modo interactivo (sem argumentos):
//      Menu clássico com impressão da primeira linha de C
// =============================================================================
int main(int argc, char *argv[])
{
    if (argc >= 3) {
        // ── Modo batch / CSV ─────────────────────────────────────────────────
        int op = atoi(argv[1]);
        int n  = atoi(argv[2]);
        int bk = (argc >= 4) ? atoi(argv[3]) : 128;

        double elapsed = 0.0;
        switch (op) {
            case 1: elapsed = OnMult(n, false);          break;
            case 2: elapsed = OnMultLine(n, false);      break;
            case 3: elapsed = OnMultBlock(n, bk, false); break;
            default:
                cerr << "Versão inválida. Use 1, 2 ou 3.\n";
                return 1;
        }

        cout << fixed
             << op << "," << n << ","
             << setprecision(6) << elapsed << ","
             << setprecision(4) << gflops(n, elapsed) << "\n";
        return 0;
    }

    // ── Modo interactivo ──────────────────────────────────────────────────────
    int op;
    do {
        cout << "\n1. Multiplication (naive)\n"
                "2. Line Multiplication (cache-friendly)\n"
                "3. Block Multiplication (tiling)\n"
                "0. Exit\n"
                "Selection?: ";
        cin >> op;
        if (op == 0) break;

        cout << "Dimensions: lins=cols ? ";
        int n; cin >> n;

        double elapsed = 0.0;
        switch (op) {
            case 1: elapsed = OnMult(n, true);      break;
            case 2: elapsed = OnMultLine(n, true);  break;
            case 3: {
                cout << "Block Size? ";
                int bk; cin >> bk;
                elapsed = OnMultBlock(n, bk, true);
                break;
            }
            default: cout << "Opção inválida.\n"; continue;
        }

        cout << fixed << setprecision(3)
             << "Time: " << elapsed << " seconds\n"
             << "Performance: " << gflops(n, elapsed) << " GFlop/s\n";

    } while (op != 0);

    return 0;
}
