#include <stdio.h>
#include <iostream>
#include <iomanip>
#include <time.h>
#include <cstdlib>

using namespace std;

#define SYSTEMTIME clock_t

 
void OnMult(int m_ar, int m_br) 
{
    SYSTEMTIME Time1, Time2;
    
    char st[100];
    double temp;
    int i, j, k;

    double *pha, *phb, *phc;

    pha = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phb = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phc = (double *)malloc((m_ar * m_ar) * sizeof(double));

    for(i = 0; i < m_ar; i++)
        for(j = 0; j < m_ar; j++)
            pha[i*m_ar + j] = 1.0;

    for(i = 0; i < m_br; i++)
        for(j = 0; j < m_br; j++)
            phb[i*m_br + j] = (double)(i + 1);

    Time1 = clock();

    for(i = 0; i < m_ar; i++)
    {
        for(j = 0; j < m_br; j++)
        {
            temp = 0;
            for(k = 0; k < m_ar; k++)
            {    
                temp += pha[i*m_ar + k] * phb[k*m_br + j];
            }
            phc[i*m_ar + j] = temp;
        }
    }

    Time2 = clock();

    double elapsed = (double)(Time2 - Time1) / CLOCKS_PER_SEC;
    double gflops  = (2.0 * (double)m_ar * (double)m_ar * (double)m_ar) /
                     (elapsed * 1.0e9);

    snprintf(st, sizeof(st), "Time: %3.3f seconds\n", elapsed);
    cout << st;
    snprintf(st, sizeof(st), "Performance: %3.3f GFlop/s\n", gflops);
    cout << st;

    cout << "Result matrix: " << endl;
    for(i = 0; i < 1; i++)
    {
        for(j = 0; j < min(10, m_br); j++)
            cout << phc[j] << " ";
    }
    cout << endl;

    free(pha);
    free(phb);
    free(phc);
}


// Line-by-line matrix multiplication (i,k,j loop order)
//
// Cache locality rationale — why we invert the j and k loops:
//
//  Naive order (i,j,k):  inner loop accesses phb[k*m_br + j]
//    → k increments by 1 each iteration, so the memory offset jumps
//      by m_br doubles (~8 KB for n=1024). Every access is a potential
//      cache-line miss (stride = row width).
//
//  Line order  (i,k,j):  inner loop accesses phb[k*m_br + j]
//    → j increments by 1 each iteration, so we walk sequentially
//      through one row of B — perfectly sequential, cache-line friendly.
//    → phc[i*m_ar + j] is also sequential (same row of C).
//    → pha[i*m_ar + k] is a scalar: loaded once per (i,k) pair and
//      kept in a register for the entire inner loop.
//
//  Net effect: all three arrays are accessed with stride-1 (or scalar),
//  maximising spatial locality and hardware prefetch efficiency.
void OnMultLine(int m_ar, int m_br)
{
    SYSTEMTIME Time1, Time2;

    char st[100];
    int i, j, k;

    double *pha, *phb, *phc;

    pha = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phb = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phc = (double *)malloc((m_ar * m_ar) * sizeof(double));

    // Initialise exactly as OnMult so results are comparable
    for (i = 0; i < m_ar; i++)
        for (j = 0; j < m_ar; j++)
            pha[i * m_ar + j] = 1.0;

    for (i = 0; i < m_br; i++)
        for (j = 0; j < m_br; j++)
            phb[i * m_br + j] = (double)(i + 1);

    // Zero C — mandatory for the ikj accumulation pattern
    for (i = 0; i < m_ar * m_ar; i++)
        phc[i] = 0.0;

    Time1 = clock();

    for (i = 0; i < m_ar; i++)
    {
        for (k = 0; k < m_ar; k++)
        {
            // Hoist the scalar load out of the innermost loop.
            // The compiler may do this anyway with -O2, but being
            // explicit avoids any aliasing-related pessimisation.
            double a_ik = pha[i * m_ar + k];

            for (j = 0; j < m_br; j++)
            {
                // Both accesses below are stride-1:
                //   phb[k*m_br + j]  → walk across row k of B
                //   phc[i*m_ar + j]  → walk across row i of C
                phc[i * m_ar + j] += a_ik * phb[k * m_br + j];
            }
        }
    }

    Time2 = clock();

    double elapsed = (double)(Time2 - Time1) / CLOCKS_PER_SEC;

    // Arithmetic intensity: each (i,j) element requires m_ar FMAs
    // → total flops = 2 * n^3  (n multiplications + n additions per entry)
    double gflops = (2.0 * (double)m_ar * (double)m_ar * (double)m_ar) /
                    (elapsed * 1.0e9);

    snprintf(st, sizeof(st), "Time: %3.3f seconds\n", elapsed);
    cout << st;
    snprintf(st, sizeof(st), "Performance: %3.3f GFlop/s\n", gflops);
    cout << st;

    cout << "Result matrix: " << endl;
    for (i = 0; i < 1; i++)
        for (j = 0; j < min(10, m_br); j++)
            cout << phc[j] << " ";
    cout << endl;

    free(pha);
    free(phb);
    free(phc);
}


// Block (tiled) matrix multiplication (i,k,j loop order within each tile)
//
// Cache-blocking rationale:
//
//  OnMultLine já garante stride-1 no loop interior, mas para matrizes
//  grandes (n >> cache) a linha inteira de B (n * 8 bytes) não cabe na
//  cache — à medida que k avança, as linhas anteriores de B são evicted.
//
//  A ideia do tiling é dividir as três matrizes em blocos de bkSize×bkSize
//  e processar um bloco de cada vez. O working set ativo é:
//      3 blocos × bkSize² × 8 bytes
//  Se bkSize for escolhido de modo a que isso caiba na L1/L2, cada
//  elemento é reutilizado bkSize vezes sem sair da cache.
//
//  Exemplo de working set por block size:
//    bkSize=128 → 3 × 128² × 8 = 393 KB  (cabe na L2 típica de 512 KB–1 MB)
//    bkSize=256 → 3 × 256² × 8 = 1.5 MB  (cabe na L3, não na L2)
//    bkSize=512 → 3 × 512² × 8 = 6 MB    (pode exceder a L3 de alguns CPUs)
//
//  Ordem dos loops externos: (ii, kk, jj)  — mantém o padrão ikj da
//  OnMultLine dentro de cada bloco: C e B acedidos sequencialmente (stride-1),
//  A[i][k] içado como escalar para registo.
void OnMultBlock(int m_ar, int m_br, int bkSize)
{
    SYSTEMTIME Time1, Time2;

    char st[100];
    int i, j, k;
    int ii, jj, kk;

    double *pha, *phb, *phc;

    pha = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phb = (double *)malloc((m_ar * m_ar) * sizeof(double));
    phc = (double *)malloc((m_ar * m_ar) * sizeof(double));

    for (i = 0; i < m_ar; i++)
        for (j = 0; j < m_ar; j++)
            pha[i * m_ar + j] = 1.0;

    for (i = 0; i < m_br; i++)
        for (j = 0; j < m_br; j++)
            phb[i * m_br + j] = (double)(i + 1);

    // C deve começar a zero — blocos de C são acumulados em múltiplas passes
    for (i = 0; i < m_ar * m_ar; i++)
        phc[i] = 0.0;

    Time1 = clock();

    // Loops externos: iteram sobre blocos (tiles) das três matrizes
    for (ii = 0; ii < m_ar; ii += bkSize)
    {
        for (kk = 0; kk < m_ar; kk += bkSize)
        {
            for (jj = 0; jj < m_br; jj += bkSize)
            {
                // Limites do bloco atual — cláusula de guarda para o caso
                // em que n não é múltiplo de bkSize
                int i_max = min(ii + bkSize, m_ar);
                int k_max = min(kk + bkSize, m_ar);
                int j_max = min(jj + bkSize, m_br);

                // Loops internos: ordem ikj dentro do bloco
                // → mesmo padrão cache-friendly da OnMultLine,
                //   mas agora o working set ativo é apenas 3 × bkSize² doubles
                for (i = ii; i < i_max; i++)
                {
                    for (k = kk; k < k_max; k++)
                    {
                        // Escalar içado para registo: 0 loads no loop j
                        double a_ik = pha[i * m_ar + k];

                        for (j = jj; j < j_max; j++)
                        {
                            phc[i * m_ar + j] += a_ik * phb[k * m_br + j];
                        }
                    }
                }
            }
        }
    }

    Time2 = clock();

    double elapsed = (double)(Time2 - Time1) / CLOCKS_PER_SEC;
    double gflops  = (2.0 * (double)m_ar * (double)m_ar * (double)m_ar) /
                     (elapsed * 1.0e9);

    snprintf(st, sizeof(st), "Time: %3.3f seconds\n", elapsed);
    cout << st;
    snprintf(st, sizeof(st), "Performance: %3.3f GFlop/s\n", gflops);
    cout << st;

    cout << "Result matrix: " << endl;
    for (i = 0; i < 1; i++)
        for (j = 0; j < min(10, m_br); j++)
            cout << phc[j] << " ";
    cout << endl;

    free(pha);
    free(phb);
    free(phc);
}


int main(int argc, char *argv[])
{
    int lin, col, blockSize;
    int op;

    do {
        cout << endl << "1. Multiplication" << endl;
        cout << "2. Line Multiplication" << endl;
        cout << "3. Block Multiplication" << endl;
        cout << "0. Exit" << endl;
        cout << "Selection?: ";
        cin >> op;

        if (op == 0)
            break;

        cout << "Dimensions: lins=cols ? ";
        cin >> lin;
        col = lin;

        switch (op) {
            case 1:
                OnMult(lin, col);
                break;
            case 2:
                OnMultLine(lin, col);
                break;
            case 3:
                cout << "Block Size? ";
                cin >> blockSize;
                OnMultBlock(lin, col, blockSize);
                break;
        }

    } while (op != 0);

    return 0;
}