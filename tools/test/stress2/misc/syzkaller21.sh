#!/bin/sh

# $ pgrep syzkaller21 | xargs ps -lHp
# UID  PID PPID CPU PRI NI   VSZ  RSS MWCHAN STAT TT     TIME COMMAND
#   0 3891    1   0  20  0 29828 2852 -      T     0  0:00,14 ./syzkaller21
#   0 3891    1   0  52  0 29828 2852 ufs    T     0  0:00,00 ./syzkaller21
#   0 3891    1   0  52  0 29828 2852 ufs    T     0  0:00,00 ./syzkaller21
# $ pgrep syzkaller21 | xargs procstat -k
#   PID    TID COMM                TDNAME              KSTACK
#  3891 100250 syzkaller21         -                   mi_switch thread_suspend_switch thread_single exit1 sys_sys_exit amd64_syscall fast_syscall_common 
#  3891 100777 syzkaller21         -                   mi_switch sleepq_switch sleeplk lockmgr_xlock_hard ffs_lock VOP_LOCK1_APV _vn_lock vget_finish vfs_hash_get ffs_vgetf softdep_sync_buf ffs_syncvnode ffs_fsync VOP_FSYNC_APV kern_fsync amd64_syscall fast_syscall_common 
#  3891 100778 syzkaller21         -                   mi_switch sleepq_switch sleeplk lockmgr_slock_hard ffs_lock VOP_LOCK1_APV _vn_lock vget_finish cache_lookup vfs_cache_lookup VOP_LOOKUP_APV lookup namei kern_chdir amd64_syscall fast_syscall_common 
# $ uname -a
# FreeBSD t2.osted.lan 13.0-CURRENT FreeBSD 13.0-CURRENT #5 r363786M: Tue Aug  4 16:51:52 CEST 2020
# pho@t2.osted.lan:/usr/src/sys/amd64/compile/PHO  amd64
# $ 

[ `uname -p` != "amd64" ] && exit 0

. ../default.cfg
cat > /tmp/syzkaller21.c <<EOF
// autogenerated by syzkaller (https://github.com/google/syzkaller)

#define _GNU_SOURCE

#include <sys/types.h>

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <pwd.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/endian.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static __thread int skip_segv;
static __thread jmp_buf segv_env;

static void segv_handler(int sig, siginfo_t* info, void* ctx __unused)
{
  uintptr_t addr = (uintptr_t)info->si_addr;
  const uintptr_t prog_start = 1 << 20;
  const uintptr_t prog_end = 100 << 20;
  if (__atomic_load_n(&skip_segv, __ATOMIC_RELAXED) &&
      (addr < prog_start || addr > prog_end)) {
    _longjmp(segv_env, 1);
  }
  exit(sig);
}

static void install_segv_handler(void)
{
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = segv_handler;
  sa.sa_flags = SA_NODEFER | SA_SIGINFO;
  sigaction(SIGSEGV, &sa, NULL);
  sigaction(SIGBUS, &sa, NULL);
}

#define NONFAILING(...)                                                        \
  {                                                                            \
    __atomic_fetch_add(&skip_segv, 1, __ATOMIC_SEQ_CST);                       \
    if (_setjmp(segv_env) == 0) {                                              \
      __VA_ARGS__;                                                             \
    }                                                                          \
    __atomic_fetch_sub(&skip_segv, 1, __ATOMIC_SEQ_CST);                       \
  }

static void kill_and_wait(int pid, int* status)
{
  kill(pid, SIGKILL);
  while (waitpid(-1, status, 0) != pid) {
  }
}

static void sleep_ms(uint64_t ms)
{
  usleep(ms * 1000);
}

static uint64_t current_time_ms(void)
{
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts))
    exit(1);
  return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static void use_temporary_dir(void)
{
  char tmpdir_template[] = "./syzkaller.XXXXXX";
  char* tmpdir = mkdtemp(tmpdir_template);
  if (!tmpdir)
    exit(1);
  if (chmod(tmpdir, 0777))
    exit(1);
  if (chdir(tmpdir))
    exit(1);
}

static void remove_dir(const char* dir)
{
  DIR* dp;
  struct dirent* ep;
  dp = opendir(dir);
  if (dp == NULL)
    exit(1);
  while ((ep = readdir(dp))) {
    if (strcmp(ep->d_name, ".") == 0 || strcmp(ep->d_name, "..") == 0)
      continue;
    char filename[FILENAME_MAX];
    snprintf(filename, sizeof(filename), "%s/%s", dir, ep->d_name);
    struct stat st;
    if (lstat(filename, &st))
      exit(1);
    if (S_ISDIR(st.st_mode)) {
      remove_dir(filename);
      continue;
    }
    if (unlink(filename))
      exit(1);
  }
  closedir(dp);
  if (rmdir(dir))
    exit(1);
}

static void thread_start(void* (*fn)(void*), void* arg)
{
  pthread_t th;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 128 << 10);
  int i;
  for (i = 0; i < 100; i++) {
    if (pthread_create(&th, &attr, fn, arg) == 0) {
      pthread_attr_destroy(&attr);
      return;
    }
    if (errno == EAGAIN) {
      usleep(50);
      continue;
    }
    break;
  }
  exit(1);
}

typedef struct {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int state;
} event_t;

static void event_init(event_t* ev)
{
  if (pthread_mutex_init(&ev->mu, 0))
    exit(1);
  if (pthread_cond_init(&ev->cv, 0))
    exit(1);
  ev->state = 0;
}

static void event_reset(event_t* ev)
{
  ev->state = 0;
}

static void event_set(event_t* ev)
{
  pthread_mutex_lock(&ev->mu);
  if (ev->state)
    exit(1);
  ev->state = 1;
  pthread_mutex_unlock(&ev->mu);
  pthread_cond_broadcast(&ev->cv);
}

static void event_wait(event_t* ev)
{
  pthread_mutex_lock(&ev->mu);
  while (!ev->state)
    pthread_cond_wait(&ev->cv, &ev->mu);
  pthread_mutex_unlock(&ev->mu);
}

static int event_isset(event_t* ev)
{
  pthread_mutex_lock(&ev->mu);
  int res = ev->state;
  pthread_mutex_unlock(&ev->mu);
  return res;
}

static int event_timedwait(event_t* ev, uint64_t timeout)
{
  uint64_t start = current_time_ms();
  uint64_t now = start;
  pthread_mutex_lock(&ev->mu);
  for (;;) {
    if (ev->state)
      break;
    uint64_t remain = timeout - (now - start);
    struct timespec ts;
    ts.tv_sec = remain / 1000;
    ts.tv_nsec = (remain % 1000) * 1000 * 1000;
    pthread_cond_timedwait(&ev->cv, &ev->mu, &ts);
    now = current_time_ms();
    if (now - start > timeout)
      break;
  }
  int res = ev->state;
  pthread_mutex_unlock(&ev->mu);
  return res;
}

struct thread_t {
  int created, call;
  event_t ready, done;
};

static struct thread_t threads[16];
static void execute_call(int call);
static int running;

static void* thr(void* arg)
{
  struct thread_t* th = (struct thread_t*)arg;
  for (;;) {
    event_wait(&th->ready);
    event_reset(&th->ready);
    execute_call(th->call);
    __atomic_fetch_sub(&running, 1, __ATOMIC_RELAXED);
    event_set(&th->done);
  }
  return 0;
}

static void execute_one(void)
{
  int i, call, thread;
  int collide = 0;
again:
  for (call = 0; call < 9; call++) {
    for (thread = 0; thread < (int)(sizeof(threads) / sizeof(threads[0]));
         thread++) {
      struct thread_t* th = &threads[thread];
      if (!th->created) {
        th->created = 1;
        event_init(&th->ready);
        event_init(&th->done);
        event_set(&th->done);
        thread_start(thr, th);
      }
      if (!event_isset(&th->done))
        continue;
      event_reset(&th->done);
      th->call = call;
      __atomic_fetch_add(&running, 1, __ATOMIC_RELAXED);
      event_set(&th->ready);
      if (collide && (call % 2) == 0)
        break;
      event_timedwait(&th->done, 45);
      break;
    }
  }
  for (i = 0; i < 100 && __atomic_load_n(&running, __ATOMIC_RELAXED); i++)
    sleep_ms(1);
  if (!collide) {
    collide = 1;
    goto again;
  }
}

static void execute_one(void);

#define WAIT_FLAGS 0

static void loop(void)
{
  int iter;
  for (iter = 0;; iter++) {
    char cwdbuf[32];
    sprintf(cwdbuf, "./%d", iter);
    if (mkdir(cwdbuf, 0777))
      exit(1);
    int pid = fork();
    if (pid < 0)
      exit(1);
    if (pid == 0) {
      if (chdir(cwdbuf))
        exit(1);
      execute_one();
      exit(0);
    }
    int status = 0;
    uint64_t start = current_time_ms();
    for (;;) {
      if (waitpid(-1, &status, WNOHANG | WAIT_FLAGS) == pid)
        break;
      sleep_ms(1);
      if (current_time_ms() - start < 5 * 1000)
        continue;
      kill_and_wait(pid, &status);
      break;
    }
    remove_dir(cwdbuf);
  }
}

uint64_t r[4] = {0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff,
                 0xffffffffffffffff};

void execute_call(int call)
{
  intptr_t res = 0;
  switch (call) {
  case 0:
    NONFAILING(memcpy((void*)0x20000000, ".\000", 2));
    res = syscall(SYS_open, 0x20000000ul, 0ul, 0ul);
    if (res != -1)
      r[0] = res;
    break;
  case 1:
    NONFAILING(memcpy((void*)0x20000040, "./file0\000", 8));
    syscall(SYS_mkdirat, r[0], 0x20000040ul, 0ul);
    break;
  case 2:
    NONFAILING(memcpy((void*)0x20000000, ".\000", 2));
    res = syscall(SYS_open, 0x20000000ul, 0ul, 0ul);
    if (res != -1)
      r[1] = res;
    break;
  case 3:
    NONFAILING(memcpy((void*)0x20000040, "./file1\000", 8));
    syscall(SYS_mkdirat, r[1], 0x20000040ul, 0ul);
    break;
  case 4:
    NONFAILING(memcpy((void*)0x20000000, ".\000", 2));
    res = syscall(SYS_open, 0x20000000ul, 0ul, 0ul);
    if (res != -1)
      r[2] = res;
    break;
  case 5:
    NONFAILING(memcpy((void*)0x20000080, "./file1\000", 8));
    NONFAILING(memcpy((void*)0x200000c0, "./file0/file0\000", 14));
    syscall(SYS_renameat, r[1], 0x20000080ul, r[2], 0x200000c0ul);
    break;
  case 6:
    NONFAILING(memcpy((void*)0x20000100, "./file0/file0\000", 14));
    res = syscall(SYS_open, 0x20000100ul, 0ul, 0ul);
    if (res != -1)
      r[3] = res;
    break;
  case 7:
    syscall(SYS_fsync, r[3]);
    break;
  case 8:
    NONFAILING(memcpy((void*)0x20000140, "./file0/file0\000", 14));
    syscall(SYS_chdir, 0x20000140ul);
    break;
  }
}
int main(void)
{
  syscall(SYS_mmap, 0x20000000ul, 0x1000000ul, 7ul, 0x1012ul, -1, 0ul);
  install_segv_handler();
  use_temporary_dir();
  loop();
  return 0;
}
EOF
mycc -o /tmp/syzkaller21 -Wall -Wextra -O2 /tmp/syzkaller21.c -lpthread ||
    exit 1

(cd ../testcases/swap; ./swap -t 1m -i 20 -h > /dev/null 2>&1) &
(cd /tmp; ./syzkaller21) &
sleep 60
while pkill swap; do sleep .2; done
pkill -9 syzkaller21
sleep .5
if pgrep -q syzkaller21; then
	pgrep syzkaller21 | xargs ps -lHp
	pgrep syzkaller21 | xargs procstat -k
	exit 1
fi
wait

rm -rf /tmp/syzkaller21.*
rm -f /tmp/syzkaller21
exit 0
