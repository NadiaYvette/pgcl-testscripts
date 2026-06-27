#include <assert.h>
#define N 3
int refcount, mapcount[N], pte[N], freed, doneA, doneB;
#define CHK() do{ assert(!(freed&&pte[0])); assert(!(freed&&pte[1])); assert(!(freed&&pte[2])); }while(0)
/* atomic increment-unless-zero: returns 1 on success, 0 if count was already 0 */
static int try_get(void){ int ok; __CPROVER_atomic_begin(); if(refcount==0){ok=0;} else {refcount++; ok=1;} __CPROVER_atomic_end(); return ok; }
int main(void){
  int s=0; refcount=1;freed=0;doneA=0;doneB=0;   /* refcount=1: the folio exists (pagecache/allocation ref) */
  mapcount[0]=mapcount[1]=mapcount[2]=0; pte[0]=pte[1]=pte[2]=0;

  __CPROVER_ASYNC_1: {
    if(try_get()){ mapcount[s]++; pte[s]=1; CHK();
      pte[s]=0; mapcount[s]--;
      __CPROVER_atomic_begin(); refcount--; int last=(refcount==0); __CPROVER_atomic_end();
      if(last) freed=1; CHK(); }
    doneA=1;
  }
  __CPROVER_ASYNC_2: {
    if(try_get()){ mapcount[s]++; pte[s]=1; CHK();
      pte[s]=0; mapcount[s]--;
      __CPROVER_atomic_begin(); refcount--; int last=(refcount==0); __CPROVER_atomic_end();
      if(last) freed=1; CHK(); }
    doneB=1;
  }
  __CPROVER_assume(doneA && doneB);
  /* drop the initial existence ref last (the allocation/pagecache ref) */
  __CPROVER_atomic_begin(); refcount--; int lastm=(refcount==0); __CPROVER_atomic_end();
  if(lastm) freed=1;
  CHK();
  return 0;
}
