/* fork_cow_diag.c — isolate the sh4 COW-write fault: child-only COW write with a
 * SIGSEGV/SIGBUS handler printing si_code + si_addr; parent (PID1) stays alive. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/reboot.h>
static void W(const char*s){(void)write(1,s,strlen(s));}
static void Wf(const char*f,...){char b[160];va_list a;__builtin_va_start(a,f);
 int n=vsnprintf(b,sizeof b,f,a);__builtin_va_end(a);(void)write(1,b,n>0?n:0);}
static volatile void *g_base; static const size_t SUB=4096;
static void segv(int sig, siginfo_t *si, void *uc){
 (void)uc;
 Wf(" CHILD FAULT sig=%d code=%d addr=%p base=%p off=%ld\n",
    sig, si->si_code, si->si_addr, (void*)g_base,
    (long)((char*)si->si_addr-(char*)g_base));
 _exit(42);
}
int main(void){
 const int N=16; size_t sz=(size_t)N*SUB;
 Wf("DIAG3 start ps=%ld\n", sysconf(_SC_PAGESIZE));
 volatile unsigned char *p=mmap(NULL,sz,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
 if(p==MAP_FAILED){W("mmap FAIL\n");goto out;}
 g_base=p;
 for(int i=0;i<N;i++) p[i*SUB]=(unsigned char)(i+1);
 pid_t pid=fork();
 if(pid==0){
  struct sigaction sa; memset(&sa,0,sizeof sa); sa.sa_sigaction=segv; sa.sa_flags=SA_SIGINFO;
  sigaction(SIGSEGV,&sa,0); sigaction(SIGBUS,&sa,0);
  int rb=0; for(int i=0;i<N;i++) if(p[i*SUB]!=(unsigned char)(i+1)) rb++;
  Wf("CHILD read: %s\n", rb?"FAIL":"ok");
  W("CHILD cow-write i=0...\n");
  p[0]=0x80;                                   /* first COW write — the suspect */
  W("CHILD cow-write i=0 OK\n");
  for(int i=2;i<N;i+=2) p[i*SUB]=(unsigned char)(0x80+i);
  int wb=0; for(int i=0;i<N;i+=2) if(p[i*SUB]!=(unsigned char)(0x80+i)) wb++;
  Wf("CHILD cow-write: %s\n", wb?"FAIL":"ok");
  _exit(wb?1:0);
 }
 int st; waitpid(pid,&st,0);
 Wf("PARENT: child exit=%d (signalled=%d)\nDIAG3 DONE\n",
    WIFEXITED(st)?WEXITSTATUS(st):-1, WIFSIGNALED(st)?WTERMSIG(st):0);
out: sync(); reboot(RB_POWER_OFF); for(;;) pause(); return 0;
}
