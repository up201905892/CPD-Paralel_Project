// =============================================================================
//  mult.cs — Multiplicação de Matrizes em C# (Fase 1: Single-core)
// =============================================================================
//
//  Versão 1 — Naïve     (i, j, k) : acesso strided a B → cache-unfriendly
//  Versão 2 — Line      (i, k, j) : stride-1 em B e C  → cache-friendly
//  Versão 3 — Block     tiling ikj : working set cabe na L2/L3
//
//  Compilar : dotnet build -c Release mult.csproj -o bin_cs
//  Executar : dotnet bin_cs/multCS.dll <versão> <n> [blocksize]
//
//  Modo batch (CSV) : dotnet bin_cs/multCS.dll <versão> <n> [blocksize]
//      Saída         : versão,n,tempo_s,gflops   (uma linha CSV)
//
//  Métrica: GFlop/s = 2·n³ / (tempo_s × 10⁹)
// =============================================================================

using System;
using System.Diagnostics;

static double GFlops(int n, double sec)
    => (2.0 * (double)n * (double)n * (double)n) / (sec * 1.0e9);

// =============================================================================
//  Versão 1 — Naïve (i, j, k)
// =============================================================================
//  Loop mais interior: temp += pha[i*n+k] * phb[k*n+j]
//    → k varia, j fixo → phb salta n doubles por iteração (stride = n)
//    → resultado: misses frequentes na L1 e L2
// =============================================================================
static double OnMult(int n, bool verbose)
{
    double[] pha = new double[n * n];
    double[] phb = new double[n * n];
    double[] phc = new double[n * n]; // zero-inicializado por defeito em C#

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    var sw = Stopwatch.StartNew();

    for (int i = 0; i < n; i++)
    {
        for (int j = 0; j < n; j++)
        {
            double temp = 0.0;
            for (int k = 0; k < n; k++)
                temp += pha[i * n + k] * phb[k * n + j]; // stride-n em phb
            phc[i * n + j] = temp;
        }
    }

    sw.Stop();
    double elapsed = sw.Elapsed.TotalSeconds;

    if (verbose)
    {
        Console.WriteLine("Result matrix:");
        for (int j = 0; j < Math.Min(n, 10); j++)
            Console.Write(phc[j] + " ");
        Console.WriteLine();
    }

    return elapsed;
}

// =============================================================================
//  Versão 2 — Line-by-line (i, k, j)
// =============================================================================
//  Inversão dos loops k ↔ j:
//    → loop interior percorre j: phb[k*n+j] e phc[i*n+j] ambos stride-1
//    → pha[i*n+k] içado como escalar → 0 loads no inner loop
//    → misses na L1/L2 reduzidos em ~8× face à versão naïve
// =============================================================================
static double OnMultLine(int n, bool verbose)
{
    double[] pha = new double[n * n];
    double[] phb = new double[n * n];
    double[] phc = new double[n * n];

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    var sw = Stopwatch.StartNew();

    for (int i = 0; i < n; i++)
    {
        for (int k = 0; k < n; k++)
        {
            double a_ik = pha[i * n + k]; // escalar — permanece em registo
            for (int j = 0; j < n; j++)
                phc[i * n + j] += a_ik * phb[k * n + j]; // stride-1
        }
    }

    sw.Stop();
    double elapsed = sw.Elapsed.TotalSeconds;

    if (verbose)
    {
        Console.WriteLine("Result matrix:");
        for (int j = 0; j < Math.Min(n, 10); j++)
            Console.Write(phc[j] + " ");
        Console.WriteLine();
    }

    return elapsed;
}

// =============================================================================
//  Versão 3 — Block/Tiling (ii, kk, jj) com inner (i, k, j)
// =============================================================================
//  Working set activo por iteração de bloco: 3 × bk² × 8 bytes
//    bk=128 → 384 KB  (cabe na L2 típica de 512 KB–1 MB)
//    bk=256 → 1.5 MB  (cabe na L3)
// =============================================================================
static double OnMultBlock(int n, int bk, bool verbose)
{
    double[] pha = new double[n * n];
    double[] phb = new double[n * n];
    double[] phc = new double[n * n];

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            pha[i * n + j] = 1.0;

    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++)
            phb[i * n + j] = (double)(i + 1);

    var sw = Stopwatch.StartNew();

    for (int ii = 0; ii < n; ii += bk)
    for (int kk = 0; kk < n; kk += bk)
    for (int jj = 0; jj < n; jj += bk)
    {
        int iMax = Math.Min(ii + bk, n);
        int kMax = Math.Min(kk + bk, n);
        int jMax = Math.Min(jj + bk, n);

        for (int i = ii; i < iMax; i++)
        for (int k = kk; k < kMax; k++)
        {
            double a_ik = pha[i * n + k];
            for (int j = jj; j < jMax; j++)
                phc[i * n + j] += a_ik * phb[k * n + j];
        }
    }

    sw.Stop();
    double elapsed = sw.Elapsed.TotalSeconds;

    if (verbose)
    {
        Console.WriteLine("Result matrix:");
        for (int j = 0; j < Math.Min(n, 10); j++)
            Console.Write(phc[j] + " ");
        Console.WriteLine();
    }

    return elapsed;
}

// =============================================================================
//  Entry point (top-level statements — C# 9 / .NET 5+)
// =============================================================================
if (args.Length >= 2)
{
    // ── Modo batch / CSV ──────────────────────────────────────────────────────
    int op = int.Parse(args[0]);
    int n  = int.Parse(args[1]);
    int bk = args.Length >= 3 ? int.Parse(args[2]) : 128;

    double elapsed = op switch
    {
        1 => OnMult(n, false),
        2 => OnMultLine(n, false),
        3 => OnMultBlock(n, bk, false),
        _ => throw new ArgumentException($"Versão inválida: {op}. Use 1, 2 ou 3.")
    };

    Console.WriteLine($"{op},{n},{elapsed:F6},{GFlops(n, elapsed):F4}");
}
else
{
    // ── Modo interactivo ──────────────────────────────────────────────────────
    int op;
    do
    {
        Console.WriteLine("\n1. Multiplication (naive)");
        Console.WriteLine("2. Line Multiplication (cache-friendly)");
        Console.WriteLine("3. Block Multiplication (tiling)");
        Console.WriteLine("0. Exit");
        Console.Write("Selection?: ");
        if (!int.TryParse(Console.ReadLine(), out op)) op = 0;
        if (op == 0) break;

        Console.Write("Dimensions: lins=cols ? ");
        if (!int.TryParse(Console.ReadLine(), out int n)) continue;

        double elapsed = 0.0;
        switch (op)
        {
            case 1: elapsed = OnMult(n, true);      break;
            case 2: elapsed = OnMultLine(n, true);  break;
            case 3:
                Console.Write("Block Size? ");
                int.TryParse(Console.ReadLine(), out int bk);
                if (bk <= 0) bk = 128;
                elapsed = OnMultBlock(n, bk, true);
                break;
            default:
                Console.WriteLine("Opção inválida.");
                continue;
        }

        Console.WriteLine($"Time: {elapsed:F3} seconds");
        Console.WriteLine($"Performance: {GFlops(n, elapsed):F4} GFlop/s");

    } while (op != 0);
}
