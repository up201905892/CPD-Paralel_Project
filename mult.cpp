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
    snprintf(st, sizeof(st), "Time: %3.3f seconds\n",
         (double)(Time2 - Time1) / CLOCKS_PER_SEC);
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


// Line-by-line matrix multiplication
void OnMultLine(int m_ar, int m_br)
{
   
}


// Block matrix multiplication
void OnMultBlock(int m_ar, int m_br, int bkSize)
{
 
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