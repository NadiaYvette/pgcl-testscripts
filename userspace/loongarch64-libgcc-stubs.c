/* Stub implementations for libgcc soft-float functions.
 * These satisfy the linker for glibc's printf/scanf long-double support.
 * LTP mm tests don't actually use floating point, so these are never called.
 */
typedef struct { long long hi, lo; } tf_t;

tf_t __addtf3(tf_t a, tf_t b) { return a; }
tf_t __subtf3(tf_t a, tf_t b) { return a; }
tf_t __multf3(tf_t a, tf_t b) { return a; }
tf_t __divtf3(tf_t a, tf_t b) { return a; }
tf_t __negtf2(tf_t a) { return a; }
int __eqtf2(tf_t a, tf_t b) { return 0; }
int __netf2(tf_t a, tf_t b) { return 0; }
int __lttf2(tf_t a, tf_t b) { return 0; }
int __letf2(tf_t a, tf_t b) { return 0; }
int __gttf2(tf_t a, tf_t b) { return 0; }
int __getf2(tf_t a, tf_t b) { return 0; }
int __unordtf2(tf_t a, tf_t b) { return 0; }
int __fixtfsi(tf_t a) { return 0; }
long long __fixtfdi(tf_t a) { return 0; }
unsigned int __fixunstfsi(tf_t a) { return 0; }
unsigned long long __fixunstfdi(tf_t a) { return 0; }
tf_t __floatsitf(int a) { tf_t r = {0,0}; return r; }
tf_t __floatditf(long long a) { tf_t r = {0,0}; return r; }
tf_t __floatunsitf(unsigned int a) { tf_t r = {0,0}; return r; }
tf_t __floatunditf(unsigned long long a) { tf_t r = {0,0}; return r; }
double __trunctfdf2(tf_t a) { return 0.0; }
float __trunctfsf2(tf_t a) { return 0.0f; }
tf_t __extendsftf2(float a) { tf_t r = {0,0}; return r; }
tf_t __extenddftf2(double a) { tf_t r = {0,0}; return r; }
float __truncdfsf2(double a) { return (float)a; }

/* pidfd_open - not in glibc yet, provide inline syscall */
int pidfd_open(int pid, unsigned int flags) {
    register long a7 __asm__("a7") = 434; /* __NR_pidfd_open */
    register long a0 __asm__("a0") = pid;
    register long a1 __asm__("a1") = flags;
    __asm__ volatile("syscall 0" : "+r"(a0) : "r"(a7), "r"(a1) : "memory");
    return a0;
}
