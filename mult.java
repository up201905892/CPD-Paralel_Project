// =============================================================================
//  mult.java — Multiplicação de Matrizes em Java (Fase 1: Single-core)
// =============================================================================
//
//  Versão 1 — Naïve     (i, j, k) : acesso strided a B → cache-unfriendly
//  Versão 2 — Line      (i, k, j) : stride-1 em B e C  → cache-friendly
//
//  Arrays 1D contíguos (double[]) replicam o layout row-major do C/C++.
//  Sem bibliotecas externas — aritmética pura para isolar efeito da JVM.
//
//  Compilar : javac mult.java
//  Executar : java MatMult                       (menu interactivo)
//             java MatMult <versão> <n>          (modo batch → linha CSV)
//             java -Xmx8g MatMult <versão> <n>  (recomendado para n grande)
//
//  Métrica: GFlop/s = 2·n³ / (tempo_s × 10⁹)
//
//  NOTA: A classe não é declarada public para permitir que o nome do ficheiro
//  (mult.java) não coincida com o nome da classe (MatMult), conforme a JLS.
// =============================================================================

import java.util.Scanner;

class MatMult {

    // ── Helper: GFlop/s ───────────────────────────────────────────────────────
    private static double gflops(int n, double sec) {
        return (2.0 * (double) n * (double) n * (double) n) / (sec * 1.0e9);
    }

    // =========================================================================
    //  Versão 1 — Naïve (i, j, k)
    // =========================================================================
    //  Loop mais interior: phb[k*n + j]
    //    → k varia, j fixo → stride = n doubles (~8 KB para n=1024)
    //    → hardware prefetcher ineficaz → misses frequentes na L1/L2
    // =========================================================================
    static double OnMult(int n, boolean verbose) {
        double[] pha = new double[n * n];
        double[] phb = new double[n * n];
        double[] phc = new double[n * n]; // Java inicializa a 0.0

        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                pha[i * n + j] = 1.0;

        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                phb[i * n + j] = (double) (i + 1);

        // phc já é zero (JLS §4.12.5) — sem necessidade de pre-touch explícito

        long t1 = System.nanoTime();

        for (int i = 0; i < n; i++) {
            for (int j = 0; j < n; j++) {
                double temp = 0.0;
                for (int k = 0; k < n; k++)
                    temp += pha[i * n + k] * phb[k * n + j]; // stride-n em phb
                phc[i * n + j] = temp;
            }
        }

        double elapsed = (System.nanoTime() - t1) / 1_000_000_000.0;

        if (verbose) {
            System.out.println("Result matrix:");
            for (int j = 0; j < Math.min(10, n); j++)
                System.out.printf("%.1f ", phc[j]);
            System.out.println();
        }

        return elapsed;
    }

    // =========================================================================
    //  Versão 2 — Line-by-line (i, k, j)
    // =========================================================================
    //  Inversão dos loops k ↔ j:
    //    → loop interior percorre j: stride-1 em phb e phc
    //    → pha[i][k] içado como escalar — 0 loads no inner loop
    //    → cache-line de 64 B serve 8 iterações consecutivas de j
    // =========================================================================
    static double OnMultLine(int n, boolean verbose) {
        double[] pha = new double[n * n];
        double[] phb = new double[n * n];
        double[] phc = new double[n * n]; // Java inicializa a 0.0 — obrigatório para +=

        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                pha[i * n + j] = 1.0;

        for (int i = 0; i < n; i++)
            for (int j = 0; j < n; j++)
                phb[i * n + j] = (double) (i + 1);

        long t1 = System.nanoTime();

        for (int i = 0; i < n; i++) {
            for (int k = 0; k < n; k++) {
                double a_ik = pha[i * n + k]; // escalar em registo
                for (int j = 0; j < n; j++)
                    phc[i * n + j] += a_ik * phb[k * n + j]; // stride-1
            }
        }

        double elapsed = (System.nanoTime() - t1) / 1_000_000_000.0;

        if (verbose) {
            System.out.println("Result matrix:");
            for (int j = 0; j < Math.min(10, n); j++)
                System.out.printf("%.1f ", phc[j]);
            System.out.println();
        }

        return elapsed;
    }

    // =========================================================================
    //  main
    // =========================================================================
    //  Modo batch (com argumentos):
    //      java MatMult <versão> <n>
    //      Saída: versão,n,tempo_s,gflops   ← linha CSV directa
    //
    //  Modo interactivo (sem argumentos):
    //      Menu clássico
    // =========================================================================
    public static void main(String[] args) {

        if (args.length >= 2) {
            // ── Modo batch / CSV ──────────────────────────────────────────────
            int op = Integer.parseInt(args[0]);
            int n  = Integer.parseInt(args[1]);

            double elapsed;
            switch (op) {
                case 1  -> elapsed = OnMult(n, false);
                case 2  -> elapsed = OnMultLine(n, false);
                default -> {
                    System.err.println("Versão inválida. Use 1 ou 2.");
                    System.exit(1);
                    return;
                }
            }

            System.out.printf("%d,%d,%.6f,%.4f%n",
                    op, n, elapsed, gflops(n, elapsed));
            return;
        }

        // ── Modo interactivo ──────────────────────────────────────────────────
        Scanner sc = new Scanner(System.in);
        int op;
        do {
            System.out.println("\n1. Multiplication (naive)");
            System.out.println("2. Line Multiplication (cache-friendly)");
            System.out.println("0. Exit");
            System.out.print("Selection?: ");
            op = sc.nextInt();
            if (op == 0) break;

            System.out.print("Dimensions: lins=cols ? ");
            int n = sc.nextInt();

            double elapsed;
            switch (op) {
                case 1  -> elapsed = OnMult(n, true);
                case 2  -> elapsed = OnMultLine(n, true);
                default -> { System.out.println("Opção inválida."); continue; }
            }

            System.out.printf("Time: %.3f seconds%n", elapsed);
            System.out.printf("Performance: %.3f GFlop/s%n", gflops(n, elapsed));

        } while (op != 0);

        sc.close();
    }
}
