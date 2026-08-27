#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile int failed_directory_sync = 0;
static volatile int completed_target_rename = 0;
static _Thread_local int inside_rename = 0;

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

int fsync(int fd) {
  static int (*real_fsync)(int) = NULL;

  if (real_fsync == NULL) {
    real_fsync = dlsym(RTLD_NEXT, "fsync");
  }

  struct stat stat_buffer;
  const char *active_path = getenv("CURSOR_SIGNING_TEST_ACTIVE_PATH");
  const char *fail_when_active =
      getenv("CURSOR_SIGNING_TEST_FAIL_WHEN_ACTIVE_EXISTS");
  const char *fail_after_rename =
      getenv("CURSOR_SIGNING_TEST_FAIL_AFTER_RENAME");
  const char *fail_always =
      getenv("CURSOR_SIGNING_TEST_FAIL_DIRECTORY_SYNC_ALWAYS");

  int directory = fstat(fd, &stat_buffer) == 0 && S_ISDIR(stat_buffer.st_mode);
  int regular = fstat(fd, &stat_buffer) == 0 && S_ISREG(stat_buffer.st_mode);
  int active_exists = active_path != NULL && access(active_path, F_OK) == 0;
  int should_fail =
      directory &&
      ((fail_when_active != NULL && active_exists) ||
       (fail_after_rename != NULL && completed_target_rename != 0));

  if (regular && getenv("CURSOR_SIGNING_TEST_STAGE_SYNC_READY") != NULL) {
    touch_marker("CURSOR_SIGNING_TEST_STAGE_SYNC_READY");
    await_marker("CURSOR_SIGNING_TEST_STAGE_SYNC_GO");
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

  return real_fsync(fd);
}

int rename(const char *old_path, const char *new_path) {
  static int (*real_rename)(const char *, const char *) = NULL;

  if (real_rename == NULL) {
    real_rename = dlsym(RTLD_NEXT, "rename");
  }

  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

  int result = real_rename(old_path, new_path);

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}

int renameat(int old_directory, const char *old_path, int new_directory,
             const char *new_path) {
  static int (*real_renameat)(int, const char *, int, const char *) = NULL;

  if (real_renameat == NULL) {
    real_renameat = dlsym(RTLD_NEXT, "renameat");
  }

  int target = !inside_rename && is_target_rename(old_path, new_path);

  if (target) {
    inside_rename = 1;
    before_target_rename();
  }

  int result = real_renameat(old_directory, old_path, new_directory, new_path);

  if (target) {
    after_target_rename(result);
    inside_rename = 0;
  }

  return result;
}
