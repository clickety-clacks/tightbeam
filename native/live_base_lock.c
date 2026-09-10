#include <erl_nif.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

typedef struct {
  ErlNifMutex *mutex;
  int fd;
  char *path;
  ErlNifPid owner;
  ErlNifMonitor monitor;
} Lock;
typedef struct Pending {
  unsigned char token[32];
  Lock *lock;
  struct Pending *next;
} Pending;
static ErlNifMutex *pending_mutex;
static Pending *pending_head;
/* Always acquire pending_mutex before a resource mutex. */
static int revoke_locked(Lock *lock) {
  Pending **cursor = &pending_head;
  while (*cursor) {
    Pending *entry = *cursor;
    if (entry->lock == lock) {
      *cursor = entry->next; enif_free(entry); return 1;
    }
    cursor = &entry->next;
  }
  return 0;
}
static ErlNifResourceType *lock_type;
static ERL_NIF_TERM atom(ErlNifEnv *env, const char *s) { return enif_make_atom(env, s); }
static ERL_NIF_TERM error(ErlNifEnv *env, const char *s) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, s));
}
static void close_fd(Lock *lock) {
  if (lock->fd >= 0) { close(lock->fd); lock->fd = -1; }
}
static void destroy(ErlNifEnv *env, void *object) {
  (void)env;
  Lock *lock = object;
  close_fd(lock);
  if (lock->path) enif_free(lock->path);
  if (lock->mutex) enif_mutex_destroy(lock->mutex);
}
static void down(ErlNifEnv *env, void *object, ErlNifPid *pid, ErlNifMonitor *monitor) {
  (void)env; (void)pid;
  Lock *lock = object;
  enif_mutex_lock(pending_mutex);
  enif_mutex_lock(lock->mutex);
  int revoked = 0;
  if (enif_compare_monitors(&lock->monitor, monitor) == 0) {
    revoked = revoke_locked(lock); close_fd(lock);
  }
  enif_mutex_unlock(lock->mutex);
  enif_mutex_unlock(pending_mutex);
  if (revoked) enif_release_resource(lock);
}
static ERL_NIF_TERM acquire(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  ErlNifBinary path;
  if (!enif_inspect_binary(env, argv[0], &path) || path.size == 0 ||
      path.data[0] != '/' || memchr(path.data, 0, path.size)) return enif_make_badarg(env);
  char *name = enif_alloc(path.size + 1);
  if (!name) return error(env, "allocation_failed");
  memcpy(name, path.data, path.size); name[path.size] = 0;
  int fd = open(name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  enif_free(name);
  if (fd < 0) return error(env, "lock_open_failed");
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
      (st.st_mode & 0777) != 0600 || st.st_nlink != 1) {
    close(fd); return error(env, "invalid_lock_file");
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int code = errno; close(fd);
    return error(env, code == EWOULDBLOCK || code == EAGAIN ? "lock_busy" : "lock_failed");
  }
  Lock *lock = enif_alloc_resource(lock_type, sizeof(Lock));
  if (!lock) { close(fd); return error(env, "allocation_failed"); }
  memset(lock, 0, sizeof(*lock)); lock->fd = fd;
  lock->path = enif_alloc(path.size + 1);
  if (!lock->path) { enif_release_resource(lock); return error(env, "allocation_failed"); }
  memcpy(lock->path, path.data, path.size); lock->path[path.size] = 0;
  lock->mutex = enif_mutex_create("tightbeam_live_base_lock");
  if (!lock->mutex) { enif_release_resource(lock); return error(env, "allocation_failed"); }
  enif_self(env, &lock->owner);
  if (enif_monitor_process(env, lock, &lock->owner, &lock->monitor) != 0) {
    enif_release_resource(lock); return error(env, "owner_unavailable");
  }
  ERL_NIF_TERM result = enif_make_resource(env, lock);
  enif_release_resource(lock);
  return enif_make_tuple2(env, atom(env, "ok"), result);
}
/* The resource is an unforgeable capability, passed only to the adopting DB.
 * Change the monitored owner without closing/reopening the locked descriptor. */
static ERL_NIF_TERM claim(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Lock *lock;
  if (!enif_get_resource(env, argv[0], lock_type, (void **)&lock)) return enif_make_badarg(env);
  enif_mutex_lock(pending_mutex); enif_mutex_lock(lock->mutex);
  ERL_NIF_TERM result;
  int revoked = 0;
  if (lock->fd < 0) result = error(env, "lock_closed");
  else if (!enif_is_process_alive(env, &lock->owner)) {
    revoked = revoke_locked(lock); close_fd(lock);
    result = error(env, "owner_unavailable");
  } else {
    ErlNifPid owner; ErlNifMonitor monitor;
    enif_self(env, &owner);
    if (enif_monitor_process(env, lock, &owner, &monitor) != 0)
      result = error(env, "owner_unavailable");
    else {
      revoked = revoke_locked(lock);
      enif_demonitor_process(env, lock, &lock->monitor);
      lock->owner = owner; lock->monitor = monitor;
      result = atom(env, "ok");
    }
  }
  enif_mutex_unlock(lock->mutex); enif_mutex_unlock(pending_mutex);
  if (revoked) enif_release_resource(lock);
  return result;
}
static ERL_NIF_TERM release(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Lock *lock; ErlNifPid caller;
  if (!enif_get_resource(env, argv[0], lock_type, (void **)&lock)) return enif_make_badarg(env);
  enif_self(env, &caller);
  enif_mutex_lock(pending_mutex); enif_mutex_lock(lock->mutex);
  if (enif_compare_pids(&caller, &lock->owner) != 0) {
    enif_mutex_unlock(lock->mutex); enif_mutex_unlock(pending_mutex);
    return error(env, "not_lock_owner");
  }
  int revoked = revoke_locked(lock);
  close_fd(lock); enif_mutex_unlock(lock->mutex); enif_mutex_unlock(pending_mutex);
  if (revoked) enif_release_resource(lock);
  return atom(env, "ok");
}
/* A one-use random token keeps the resource alive; no raw fd leaves native code. */
static ERL_NIF_TERM prepare_attachment(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Lock *lock; ErlNifPid caller;
  ErlNifBinary token;
  if (!enif_get_resource(env, argv[0], lock_type, (void **)&lock) ||
      !enif_inspect_binary(env, argv[1], &token) || token.size != 32) return enif_make_badarg(env);
  enif_self(env, &caller);
  enif_mutex_lock(pending_mutex); enif_mutex_lock(lock->mutex);
  ERL_NIF_TERM result;
  if (lock->fd < 0) result = error(env, "lock_closed");
  else if (enif_compare_pids(&caller, &lock->owner) != 0) result = error(env, "not_lock_owner");
  else {
    Pending *entry = pending_head;
    while (entry && entry->lock != lock && memcmp(entry->token, token.data, 32) != 0) entry = entry->next;
    if (entry) result = error(env, "attachment_pending");
    else if (!(entry = enif_alloc(sizeof(Pending)))) result = error(env, "allocation_failed");
    else {
      memcpy(entry->token, token.data, 32); entry->lock = lock;
      enif_keep_resource(lock); entry->next = pending_head; pending_head = entry;
      result = atom(env, "ok");
    }
  }
  enif_mutex_unlock(lock->mutex);
  enif_mutex_unlock(pending_mutex);
  return result;
}
static ERL_NIF_TERM assert_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  Lock *lock; ErlNifPid caller; ErlNifBinary path;
  if (!enif_get_resource(env, argv[0], lock_type, (void **)&lock) ||
      !enif_inspect_binary(env, argv[1], &path)) return enif_make_badarg(env);
  enif_self(env, &caller);
  enif_mutex_lock(lock->mutex);
  ERL_NIF_TERM result;
  if (lock->fd < 0) result = error(env, "lock_closed");
  else if (enif_compare_pids(&caller, &lock->owner) != 0) result = error(env, "not_lock_owner");
  else if (strlen(lock->path) != path.size || memcmp(lock->path, path.data, path.size) != 0)
    result = error(env, "lock_path_mismatch");
  else result = atom(env, "ok");
  enif_mutex_unlock(lock->mutex);
  return result;
}
static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
  (void)priv; (void)info;
  pending_mutex = enif_mutex_create("live_base_pending");
  if (!pending_mutex) return -1;
  ErlNifResourceTypeInit init = {.dtor = destroy, .down = down};
  lock_type = enif_open_resource_type_x(env, "live_base_lock", &init, ERL_NIF_RT_CREATE, NULL);
  return lock_type ? 0 : -1;
}
static ErlNifFunc funcs[] = {
  {"acquire", 1, acquire, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"assert_path", 2, assert_path, 0},
  {"prepare_attachment", 2, prepare_attachment, 0},
  {"claim", 1, claim, 0}, {"release", 1, release, ERL_NIF_DIRTY_JOB_IO_BOUND}
};
ERL_NIF_INIT(Elixir.Tightbeam.LiveBaseLock, funcs, load, NULL, NULL, NULL)

typedef struct { int fd; } Attachment;
static void attachment_destroy(void *object) {
  Attachment *attachment = object;
  if (attachment->fd >= 0) close(attachment->fd);
  sqlite3_free(attachment);
}
static void attach(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  (void)argc;
  Attachment *attachment = sqlite3_user_data(ctx);
  if (attachment->fd >= 0 || sqlite3_value_bytes(argv[0]) != 32) {
    sqlite3_result_error(ctx, "invalid or repeated lock attachment", -1); return;
  }
  const void *token = sqlite3_value_blob(argv[0]);
  enif_mutex_lock(pending_mutex);
  Pending **cursor = &pending_head;
  while (*cursor && memcmp((*cursor)->token, token, 32) != 0) cursor = &(*cursor)->next;
  Pending *entry = *cursor;
  if (!entry) {
    enif_mutex_unlock(pending_mutex);
    sqlite3_result_error(ctx, "unknown attachment capability", -1); return;
  }
  Lock *lock = entry->lock;
  enif_mutex_lock(lock->mutex);
  ErlNifEnv *env = enif_alloc_env();
  int duplicate = -1;
  if (env && lock->fd >= 0 && enif_is_process_alive(env, &lock->owner))
    duplicate = fcntl(lock->fd, F_DUPFD_CLOEXEC, 0);
  if (env) enif_free_env(env);
  *cursor = entry->next; enif_free(entry);
  enif_mutex_unlock(lock->mutex); enif_mutex_unlock(pending_mutex);
  enif_release_resource(lock);
  if (duplicate < 0) { sqlite3_result_error(ctx, "attachment owner unavailable", -1); return; }
  attachment->fd = duplicate;
  sqlite3_result_int(ctx, 1);
}
int sqlite3_livebaselock_init(sqlite3 *db, char **error_message,
                            const sqlite3_api_routines *api) {
  (void)error_message;
  enif_mutex_lock(pending_mutex);
  if (sqlite3_api && sqlite3_api != api) {
    enif_mutex_unlock(pending_mutex); return SQLITE_MISUSE;
  }
  if (!sqlite3_api) { SQLITE_EXTENSION_INIT2(api); }
  enif_mutex_unlock(pending_mutex);
  Attachment *attachment = sqlite3_malloc(sizeof(Attachment));
  if (!attachment) return SQLITE_NOMEM;
  attachment->fd = -1;
  /* The function destructor runs at actual SQLite destruction, including
   * deferred close_v2 after the last surviving statement is finalized.
   * DIRECTONLY prevents schema-controlled invocation. This private function
   * is never an admission API and must not be exposed through the wire. */
  return sqlite3_create_function_v2(db, "tightbeam_attach_base_lock", 1,
    SQLITE_UTF8 | SQLITE_DIRECTONLY, attachment, attach, NULL, NULL, attachment_destroy);
}

/* Ordinary SQLite inspection may maintain coordination sidecars, but must
 * never checkpoint on close before admission. This connection-local setting
 * does not change the later writable DB owner's checkpoint policy. */
int sqlite3_livebaseinspection_init(sqlite3 *db, char **error_message,
                                  const sqlite3_api_routines *api) {
  int rc = sqlite3_livebaselock_init(db, error_message, api);
  if (rc != SQLITE_OK) return rc;
  int enabled = 0;
  rc = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
  if (rc != SQLITE_OK) return rc;
  return enabled == 1 ? SQLITE_OK : SQLITE_ERROR;
}
