import java.util.Scanner;

/**
 * MatMult.java — Multiplicação de Matrizes em Java (Single-core)
 *
 * Equivalente direto do mult.cpp para fins de comparação de desempenho
 * entre linguagens. Usa arrays 1D contíguos (double[]) para replicar
 * o layout row-major do malloc C (pha[i*n + j]).
 *
 * Sem bibliotecas externas — aritmética pura para isolar o efeito
 * da JVM e da cache.
 *
 * Compilar : javac MatMult.java
 * Executar : java MatMult
 *            java -server MatMult          (JIT agressivo — recomendado)
 *            java -Xss64m MatMult          (stack grande, por precaução)
 */
public class MatMult {

    // ------------------------------------------------------------------ //
    //  Utilitário de tempo                                                //
    // ------------------------------------------------------------------ //

    /**
     * Devolve o tempo decorrido em segundos com resolução de nanosegundos.
     * System.nanoTime() é monotónico e adequado para benchmarks; ao contrário
     * de currentTimeMillis(), não é afetado por ajustes de relógio do SO.
     */
    private static double elapsed(long startNs) {
        return (System.nanoTime() - startNs) / 1_000_000_000.0;
    }

    /**
     * GFlop/s para multiplicação de matrizes quadradas n×n.
     * Complexidade aritmética exacta: 2·n³ flops
     *   (n² produtos + n² somas, cada um repetido n vezes ao longo de k)
     */
    private static double gflops(int n, double seconds) {
        return (2.0 * (double) n * (double) n * (double) n) / (seconds * 1.0e9);
    }

    // ------------------------------------------------------------------ //
    //  Impressão dos resultados (linha zero de C, primeiros 10 elementos) //
    // ------------------------------------------------------------------ //

    private static void printResult(double[] phc, int cols) {
        System.out.println("Result matrix:");
        int limit = Math.min(10, cols);
        for (int j = 0; j < limit; j++) {
            System.out.printf("%.1f ", phc[j]);
        }
        System.out.println();
    }

    // ------------------------------------------------------------------ //
    //  OnMult — ordem naive (i, j, k)                                    //
    // ------------------------------------------------------------------ //
    //
    //  Acesso ao loop mais interior:
    //      phb[k * n + j]  →  k varia, j fixo  →  stride = n doubles
    //  Para n = 1024: cada passo de k salta 8 KB em memória.
    //  O hardware prefetcher não consegue prever este padrão strided,
    //  resultando em cache misses frequentes na L1/L2.
    //
    static void OnMult(int m_ar, int m_br) {
        // Alocação de arrays 1D contíguos — equivalente ao malloc C
        // Java inicializa double[] a 0.0 por defeito (JLS §4.12.5)
        double[] pha = new double[m_ar * m_ar];
        double[] phb = new double[m_ar * m_ar];
        double[] phc = new double[m_ar * m_ar];

        // Inicialização idêntica ao C++ para comparação justa
        for (int i = 0; i < m_ar; i++)
            for (int j = 0; j < m_ar; j++)
                pha[i * m_ar + j] = 1.0;

        for (int i = 0; i < m_br; i++)
            for (int j = 0; j < m_br; j++)
                phb[i * m_br + j] = (double) (i + 1);

        // ----- Kernel de multiplicação -----
        long t1 = System.nanoTime();

        for (int i = 0; i < m_ar; i++) {
            for (int j = 0; j < m_br; j++) {
                double temp = 0.0;
                for (int k = 0; k < m_ar; k++) {
                    // phb[k*n + j]: stride strided — potencial miss por iteração
                    temp += pha[i * m_ar + k] * phb[k * m_br + j];
                }
                phc[i * m_ar + j] = temp;
            }
        }

        double secs = elapsed(t1);
        System.out.printf("Time: %.3f seconds%n", secs);
        System.out.printf("Performance: %.3f GFlop/s%n", gflops(m_ar, secs));
        printResult(phc, m_br);
    }

    // ------------------------------------------------------------------ //
    //  OnMultLine — ordem cache-friendly (i, k, j)                       //
    // ------------------------------------------------------------------ //
    //
    //  Inversão dos loops k ↔ j elimina o acesso strided:
    //
    //  Loop mais interior (j varia, k e i fixos):
    //      phb[k * n + j]  →  stride-1  (percorre linha k de B sequencialmente)
    //      phc[i * n + j]  →  stride-1  (percorre linha i de C sequencialmente)
    //      pha[i * n + k]  →  escalar içado para registo (0 loads no inner loop)
    //
    //  Cada cache-line de 64 bytes carrega 8 doubles e serve 8 iterações
    //  consecutivas de j — reuse factor de 8× vs 1× no naive.
    //
    //  Pré-condição: phc[] deve estar a zero antes da acumulação (+=).
    //  Java garante isso automaticamente na alocação (double[] → 0.0).
    //
    static void OnMultLine(int m_ar, int m_br) {
        double[] pha = new double[m_ar * m_ar];
        double[] phb = new double[m_ar * m_ar];
        double[] phc = new double[m_ar * m_ar]; // Java inicializa a 0.0

        for (int i = 0; i < m_ar; i++)
            for (int j = 0; j < m_ar; j++)
                pha[i * m_ar + j] = 1.0;

        for (int i = 0; i < m_br; i++)
            for (int j = 0; j < m_br; j++)
                phb[i * m_br + j] = (double) (i + 1);

        // ----- Kernel de multiplicação -----
        long t1 = System.nanoTime();

        for (int i = 0; i < m_ar; i++) {
            for (int k = 0; k < m_ar; k++) {
                // Içar o escalar para fora do loop j.
                // Evita que o compilador JIT re-leia pha[] a cada iteração
                // por incerteza de aliasing (embora arrays Java não se
                // alinhem, o JIT pode não provar isso sem a variável local).
                double a_ik = pha[i * m_ar + k];

                for (int j = 0; j < m_br; j++) {
                    // stride-1 em phb e phc — prefetch automático eficaz
                    phc[i * m_ar + j] += a_ik * phb[k * m_br + j];
                }
            }
        }

        double secs = elapsed(t1);
        System.out.printf("Time: %.3f seconds%n", secs);
        System.out.printf("Performance: %.3f GFlop/s%n", gflops(m_ar, secs));
        printResult(phc, m_br);
    }

    // ------------------------------------------------------------------ //
    //  main — menu interativo                                             //
    // ------------------------------------------------------------------ //

    public static void main(String[] args) {
        Scanner sc = new Scanner(System.in);
        int op;

        do {
            System.out.println();
            System.out.println("1. Multiplication");
            System.out.println("2. Line Multiplication");
            System.out.println("0. Exit");
            System.out.print("Selection?: ");
            op = sc.nextInt();

            if (op == 0) break;

            System.out.print("Dimensions: lins=cols ? ");
            int n = sc.nextInt();

            switch (op) {
                case 1 -> OnMult(n, n);
                case 2 -> OnMultLine(n, n);
                default -> System.out.println("Invalid option.");
            }

        } while (op != 0);

        sc.close();
    }
}
