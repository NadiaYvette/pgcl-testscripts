#include <assert.h>
#define N 3
int refcount, mapcount[N], pte[N], freed, doneA, doneB;
int ptl;   /* page-table lock (0=free,1=held); CBMC atomic via __CPROVER_atomic_begin */
#define CHK() do{ assert(!(freed&&pte[0])); assert(!(freed&&pte[1])); assert(!(freed&&pte[2])); }while(0)
/* acquire/release as atomic test-and-set spin */
#define LOCK()   do{ int g; do{ __CPROVER_atomic_begin(); g=ptl; if(!g) ptl=1; __CPROVER_atomic_end(); }while(g); }while(0)
#define UNLOCK() do{ __CPROVER_atomic_begin(); ptl=0; __CPROVER_atomic_end(); }while(0)
int main(void){
  int s=0; refcount=0;freed=0;doneA=0;doneB=0;ptl=0;
  mapcount[0]=mapcount[1]=mapcount[2]=0; pte[0]=pte[1]=pte[2]=0;
  __CPROVER_ASYNC_1: {
    LOCK(); mapcount[s]++; refcount++; pte[s]=1; CHK();
            pte[s]=0; mapcount[s]--; refcount--; if(refcount==0) freed=1; CHK(); UNLOCK();
    doneA=1;
  }
  __CPROVER_ASYNC_2: {
    LOCK(); mapcount[s]++; refcount++; pte[s]=1; CHK();
            pte[s]=0; mapcount[s]--; refcount--; if(refcount==0) freed=1; CHK(); UNLOCK();
    doneB=1;
  }
  __CPROVER_assume(doneA && doneB);
  CHK();
  return 0;
}
