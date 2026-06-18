#ifndef _SYS_PIDFD_H
#define _SYS_PIDFD_H
/* Stub shim: LTP config.h has HAVE_SYS_PIDFD_H/HAVE_PIDFD_OPEN (host glibc),
 * but musl provides neither this header nor the libc pidfd_* wrappers, so
 * lapi/pidfd.h skips its own fallbacks and the link fails on pidfd_open.
 * Provide thin syscall wrappers (SYS_pidfd_* are in musl's <sys/syscall.h>). */
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>
#include <signal.h>

static inline int pidfd_open(pid_t pid, unsigned int flags)
{
	return syscall(SYS_pidfd_open, pid, flags);
}
static inline int pidfd_send_signal(int pidfd, int sig, siginfo_t *info,
				    unsigned int flags)
{
	return syscall(SYS_pidfd_send_signal, pidfd, sig, info, flags);
}
static inline int pidfd_getfd(int pidfd, int targetfd, unsigned int flags)
{
	return syscall(SYS_pidfd_getfd, pidfd, targetfd, flags);
}
#endif
