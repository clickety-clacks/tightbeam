#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#if defined(__APPLE__)
#include <sys/syscall.h>
#endif
#include <unistd.h>

static volatile int failed_directory_sync = 0;
static volatile int completed_target_rename = 0;
static volatile int exclusive_lock_count = 0;
static _Thread_local int inside_rename = 0;

#if defined(__APPLE__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#define PROBE_FUNCTION(name) cursor_signing_probe_##name
#define DYLD_INTERPOSE(replacement, replacee)                                 \
  __attribute__((used)) static struct {                                       \
    const void *replacement;                                                  \
    const void *replacee;                                                     \
  } interpose_##replacement __attribute__((section("__DATA,__interpose"))) = { \
      (const void *)(unsigned long)&replacement,                              \
      (const void *)(unsigned long)&replacee};
#else
#define PROBE_FUNCTION(name) name
#endif

static void touch_marker(const char *environment_name) {
  const char *path = getenv(environment_name);

  if (path == NULL || path[0] == '\0') {
    return;
  }

  int fd = open(path, O_CREAT | O_WRONLY, 0600);

  if (fd >= 0) {
    close(fd);
  }
}

__attribute__((constructor)) static void probe_loaded(void) {
  touch_marker("CURSOR_SIGNING_TEST_PROBE_READY");
}

static void await_marker(const char *environment_name) {
  const char *path = getenv(environment_name);

  if (path == NULL || path[0] == '\0') {
    return;
  }

  while (access(path, F_OK) != 0) {
    usleep(1000);
  }
}

static int is_target_rename(const char *old_path, const char *new_path) {
  const char *active_path = getenv("CURSOR_SIGNING_TEST_ACTIVE_PATH");

  return active_path != NULL && old_path != NULL && new_path != NULL &&
         strcmp(new_path, active_path) == 0 &&
         (strstr(old_path, ".rest-cursor-signing.v1.rotate-") != NULL ||
          strstr(old_path, ".rest-cursor-signing.v1.provision-") != NULL);
}

static int is_target_temporary_path(const char *path, const char *active_path) {
  static const char provision_prefix[] =
      ".rest-cursor-signing.v1.provision-";
  static const char rotation_prefix[] = ".rest-cursor-signing.v1.rotate-";
  const char *path_name;
  const char *active_name;
  const char *temporary_name;
  size_t path_directory_length;
  size_t active_directory_length;
  char path_directory[PATH_MAX];
  char active_directory[PATH_MAX];
  struct stat path_directory_stat;
  struct stat active_directory_stat;

  if (path == NULL || active_path == NULL) {
    return 0;
  }

  path_name = strrchr(path, '/');
  active_name = strrchr(active_path, '/');

  if (path_name == NULL || active_name == NULL) {
    return 0;
  }

  path_directory_length = (size_t)(path_name - path);
  active_directory_length = (size_t)(active_name - active_path);

  if (path_directory_length >= sizeof(path_directory) ||
      active_directory_length >= sizeof(active_directory)) {
    return 0;
  }

  memcpy(path_directory, path, path_directory_length);
  path_directory[path_directory_length] = '\0';
  memcpy(active_directory, active_path, active_directory_length);
  active_directory[active_directory_length] = '\0';

  if (stat(path_directory, &path_directory_stat) != 0 ||
      stat(active_directory, &active_directory_stat) != 0 ||
      path_directory_stat.st_dev != active_directory_stat.st_dev ||
      path_directory_stat.st_ino != active_directory_stat.st_ino) {
    return 0;
  }

  temporary_name = path_name + 1;

  return (strncmp(temporary_name, provision_prefix,
                  sizeof(provision_prefix) - 1) == 0 &&
          temporary_name[sizeof(provision_prefix) - 1] != '\0') ||
         (strncmp(temporary_name, rotation_prefix,
                  sizeof(rotation_prefix) - 1) == 0 &&
          temporary_name[sizeof(rotation_prefix) - 1] != '\0');
}

static int is_target_temporary_fd(int fd, const char *active_path) {
  char path[PATH_MAX];

#if defined(__APPLE__)
  if (syscall(SYS_fcntl, fd, F_GETPATH, path) != 0) {
    return 0;
  }
#else
  char descriptor_path[64];
  int descriptor_length =
      snprintf(descriptor_path, sizeof(descriptor_path), "/proc/self/fd/%d", fd);

  if (descriptor_length < 0 ||
      (size_t)descriptor_length >= sizeof(descriptor_path)) {
    return 0;
  }

  ssize_t path_length = readlink(descriptor_path, path, sizeof(path) - 1);

  if (path_length < 0) {
    return 0;
  }

  path[path_length] = '\0';
#endif

  return is_target_temporary_path(path, active_path);
}

static void before_target_rename(void) {
  touch_marker("CURSOR_SIGNING_TEST_RENAME_READY");
  await_marker("CURSOR_SIGNING_TEST_RENAME_GO");
}

static void after_target_rename(int result) {
  if (result != 0) {
    return;
  }

  __sync_lock_test_and_set(&completed_target_rename, 1);
  touch_marker("CURSOR_SIGNING_TEST_RENAME_DONE");
  await_marker("CURSOR_SIGNING_TEST_RENAME_FINISH");
}

static int before_sync(int fd) {
  struct stat stat_buffer;
  const char *active_path = getenv("CURSOR_SIGNING_TEST_ACTIVE_PATH");
  const char *fail_when_active =
      getenv("CURSOR_SIGNING_TEST_FAIL_WHEN_ACTIVE_EXISTS");
  const char *fail_after_rename =
      getenv("CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME");
  const char *fail_always =
      getenv("CURSOR_SIGNING_TEST_FAIL_DIRECTORY_SYNC_ALWAYS");
  const char *recovery_sync_arm =
      getenv("CURSOR_SIGNING_TEST_RECOVERY_SYNC_ARM");
  const char *fail_recovery_sync =
      getenv("CURSOR_SIGNING_TEST_FAIL_RECOVERY_SYNC_WHEN_ARMED");

  int directory = fstat(fd, &stat_buffer) == 0 && S_ISDIR(stat_buffer.st_mode);
  int regular = fstat(fd, &stat_buffer) == 0 && S_ISREG(stat_buffer.st_mode);
  int target_temporary = regular && is_target_temporary_fd(fd, active_path);
  int active_exists = active_path != NULL && access(active_path, F_OK) == 0;
  int recovery_sync_armed = recovery_sync_arm != NULL &&
                            access(recovery_sync_arm, F_OK) == 0;
  int should_fail =
      directory &&
      ((fail_when_active != NULL && active_exists) ||
       (fail_after_rename != NULL && completed_target_rename != 0) ||
       (fail_recovery_sync != NULL && recovery_sync_armed));

  if (target_temporary &&
      getenv("CURSOR_SIGNING_TEST_FAIL_STAGE_SYNC_ALWAYS") != NULL) {
    touch_marker("CURSOR_SIGNING_TEST_FSYNC_FAILED");
    errno = EIO;
    return -1;
  }

  if (target_temporary &&
      getenv("CURSOR_SIGNING_TEST_STAGE_SYNC_READY") != NULL) {
    touch_marker("CURSOR_SIGNING_TEST_STAGE_SYNC_READY");
    await_marker("CURSOR_SIGNING_TEST_STAGE_SYNC_GO");
  }

  if (directory && recovery_sync_armed &&
      getenv("CURSOR_SIGNING_TEST_RECOVERY_SYNC_READY") != NULL) {
    touch_marker("CURSOR_SIGNING_TEST_RECOVERY_SYNC_READY");
    await_marker("CURSOR_SIGNING_TEST_RECOVERY_SYNC_GO");
  }

  if (directory && completed_target_rename != 0 &&
      getenv("CURSOR_SIGNING_TEST_DIR_SYNC_READY") != NULL) {
    touch_marker("CURSOR_SIGNING_TEST_DIR_SYNC_READY");
    await_marker("CURSOR_SIGNING_TEST_DIR_SYNC_GO");
  }

  if (should_fail &&
      (fail_always != NULL ||
       __sync_bool_compare_and_swap(&failed_directory_sync, 0, 1))) {
    touch_marker("CURSOR_SIGNING_TEST_FSYNC_FAILED");
    errno = EIO;
    return -1;
  }

  return 0;
}

int PROBE_FUNCTION(fsync)(int fd) {
  if (before_sync(fd) != 0) {
    return -1;
  }

#if defined(__APPLE__)
  return (int)syscall(SYS_fsync, fd);
#else
  static int (*real_fsync)(int) = NULL;

  if (real_fsync == NULL) {
    real_fsync = dlsym(RTLD_NEXT, "fsync");
  }

  return real_fsync(fd);
#endif
}

#if defined(__APPLE__)
/*
 * C cannot safely recover an opaque argument from Darwin's variadic fcntl
 * entry: no-argument commands have no value to read, and other commands pass
 * either an int or a pointer. This ABI trampoline preserves the raw argument
 * slot without interpreting it. arm64 places variadic arguments on the stack;
 * x86_64 already places the third argument in the fixed-width third slot.
 */
_Static_assert(sizeof(long) == sizeof(void *),
               "Darwin fcntl forwarding requires LP64");
extern int cursor_signing_probe_fcntl(int fd, int command, ...);

#if defined(__arm64__)
__asm__(".text\n"
        ".globl _cursor_signing_probe_fcntl\n"
        "_cursor_signing_probe_fcntl:\n"
        "  ldr x2, [sp]\n"
        "  b _cursor_signing_probe_fcntl_impl\n");
#elif defined(__x86_64__)
__asm__(".text\n"
        ".globl _cursor_signing_probe_fcntl\n"
        "_cursor_signing_probe_fcntl:\n"
        "  jmp _cursor_signing_probe_fcntl_impl\n");
#else
#error "Darwin fcntl forwarding requires a supported ABI"
#endif

int cursor_signing_probe_fcntl_impl(int fd, int command, long argument) {
  long kernel_argument = argument;

  switch (command) {
  case F_GETFD:
  case F_GETFL:
  case F_GETOWN:
  case F_FLUSH_DATA:
  case F_CHKCLEAN:
  case F_FULLFSYNC:
  case F_FREEZE_FS:
  case F_THAW_FS:
  case F_GETPROTECTIONCLASS:
  case F_GETNOSIGPIPE:
  case F_GETPROTECTIONLEVEL:
  case F_BARRIERFSYNC:
  case F_GETLEASE:
    kernel_argument = 0;
    break;

  default:
    break;
  }

  if ((command == F_FULLFSYNC || command == F_BARRIERFSYNC) &&
      before_sync(fd) != 0) {
    return -1;
  }

  return (int)syscall(SYS_fcntl, fd, command, kernel_argument);
}
#endif

int PROBE_FUNCTION(flock)(int fd, int operation) {
#if !defined(__APPLE__)
  static int (*real_flock)(int, int) = NULL;

  if (real_flock == NULL) {
    real_flock = dlsym(RTLD_NEXT, "flock");
  }
#endif

#if defined(__APPLE__)
  int result = (int)syscall(SYS_flock, fd, operation);
#else
  int result = real_flock(fd, operation);
#endif

  if (result == 0 && (operation & LOCK_EX) != 0) {
    int ordinal = __sync_add_and_fetch(&exclusive_lock_count, 1);
    const char *expected = getenv("CURSOR_SIGNING_TEST_LOCK_ORDINAL");

    if (expected != NULL && ordinal == atoi(expected)) {
      touch_marker("CURSOR_SIGNING_TEST_LOCK_READY");
      await_marker("CURSOR_SIGNING_TEST_LOCK_GO");
    }
  }

  return result;
}

int PROBE_FUNCTION(rename)(const char *old_path, const char *new_path) {
#if !defined(__APPLE__)
  static int (*real_rename)(const char *, const char *) = NULL;

  if (real_rename == NULL) {
    real_rename = dlsym(RTLD_NEXT, "rename");
  }
#endif

  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

#if defined(__APPLE__)
  int result = (int)syscall(SYS_rename, old_path, new_path);
#else
  int result = real_rename(old_path, new_path);
#endif

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}

int PROBE_FUNCTION(renameat)(int old_directory, const char *old_path,
                             int new_directory, const char *new_path) {
#if !defined(__APPLE__)
  static int (*real_renameat)(int, const char *, int, const char *) = NULL;

  if (real_renameat == NULL) {
    real_renameat = dlsym(RTLD_NEXT, "renameat");
  }
#endif

  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

#if defined(__APPLE__)
  int result =
      (int)syscall(SYS_renameat, old_directory, old_path, new_directory,
                   new_path);
#else
  int result = real_renameat(old_directory, old_path, new_directory, new_path);
#endif

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}

#if defined(__linux__)
int renameat2(int old_directory, const char *old_path, int new_directory,
              const char *new_path, unsigned int flags) {
  static int (*real_renameat2)(int, const char *, int, const char *,
                              unsigned int) = NULL;

  if (real_renameat2 == NULL) {
    real_renameat2 = dlsym(RTLD_NEXT, "renameat2");
  }

  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

  int result =
      real_renameat2(old_directory, old_path, new_directory, new_path, flags);

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}
#endif

#if defined(__APPLE__)
int PROBE_FUNCTION(renameatx_np)(int old_directory, const char *old_path,
                                 int new_directory, const char *new_path,
                                 unsigned int flags) {
  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

  int result =
      (int)syscall(SYS_renameatx_np, old_directory, old_path, new_directory,
                   new_path, flags);

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}

DYLD_INTERPOSE(cursor_signing_probe_fsync, fsync)
DYLD_INTERPOSE(cursor_signing_probe_fcntl, fcntl)
DYLD_INTERPOSE(cursor_signing_probe_flock, flock)
DYLD_INTERPOSE(cursor_signing_probe_rename, rename)
DYLD_INTERPOSE(cursor_signing_probe_renameat, renameat)
DYLD_INTERPOSE(cursor_signing_probe_renameatx_np, renameatx_np)
#pragma clang diagnostic pop
#endif
