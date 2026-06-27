#include <assert.h>
#define N 3
int refcount, mapcount[N], pte[N], freed, doneA, doneB;
#define CHK() do{ assert(!(freed&&pte[0])); assert(!(freed&&pte[1])); assert(!(freed&&pte[2])); }while(0)
int main(void){
  int s=0; refcount=0;freed=0;doneA=0;doneB=0;
  mapcount[0]=mapcount[1]=mapcount[2]=0; pte[0]=pte[1]=pte[2]=0;

  __CPROVER_ASYNC_1: {
    /* fault/add: ATOMIC ref-get happens-before the PTE is observable */
    __CPROVER_atomic_begin(); refcount++; __CPROVER_atomic_end();
    mapcount[s]++; pte[s]=1; CHK();
    /* zap: clear PTE first, then ATOMIC dec-and-test; free iff WE saw 0 */
    pte[s]=0; mapcount[s]--;
    __CPROVER_atomic_begin(); refcount--; int last = (refcount==0); __CPROVER_atomic_end();
    if(last) freed=1;
    CHK();
    doneA=1;
  }
  __CPROVER_ASYNC_2: {
    __CPROVER_atomic_begin(); refcount++; __CPROVER_atomic_end();
    mapcount[s]++; pte[s]=1; CHK();
    pte[s]=0; mapcount[s]--;
    __CPROVER_atomic_begin(); refcount--; int last = (refcount==0); __CPROVER_atomic_end();
    if(last) freed=1;
    CHK();
    doneB=1;
  }
  __CPROVER_assume(doneA && doneB);
  CHK();
  return 0;
}
