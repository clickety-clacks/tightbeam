#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#include "erl_nif.h"

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

typedef struct {
  int fd;
} lock_resource;

static ErlNifResourceType *lock_resource_type = NULL;

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  return enif_make_atom(env, name);
}

static ERL_NIF_TERM error_tuple(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static int path_argument(ErlNifEnv *env, ERL_NIF_TERM term, char **path) {
  ErlNifBinary binary;

  if (!enif_inspect_binary(env, term, &binary) ||
      memchr(binary.data, '\0', binary.size) != NULL) {
    return 0;
  }

  *path = enif_alloc(binary.size + 1);

  if (*path == NULL) {
    return 0;
  }

  memcpy(*path, binary.data, binary.size);
  (*path)[binary.size] = '\0';
  return 1;
}

static void close_lock(lock_resource *resource) {
  if (resource->fd >= 0) {
    (void)flock(resource->fd, LOCK_UN);
    (void)close(resource->fd);
    resource->fd = -1;
  }
}

static void lock_destructor(ErlNifEnv *env, void *object) {
  (void)env;
  close_lock((lock_resource *)object);
}

static ERL_NIF_TERM acquire_lock(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  char *path = NULL;
  char mode[16];
  char target[16];
  int open_flags;
  int operation;
  int fd;
  lock_resource *resource;
  ERL_NIF_TERM handle;

  if (argc != 3 || !path_argument(env, argv[0], &path) ||
      enif_get_atom(env, argv[1], mode, sizeof(mode), ERL_NIF_LATIN1) <= 0 ||
      enif_get_atom(env, argv[2], target, sizeof(target), ERL_NIF_LATIN1) <= 0) {
    if (path != NULL) {
      enif_free(path);
    }

    return enif_make_badarg(env);
  }

  if (strcmp(mode, "shared") == 0) {
    operation = LOCK_SH | LOCK_NB;
  } else if (strcmp(mode, "exclusive") == 0) {
    operation = LOCK_EX | LOCK_NB;
  } else {
    enif_free(path);
    return enif_make_badarg(env);
  }

  if (strcmp(target, "directory") == 0) {
    open_flags = O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW;
  } else if (strcmp(target, "record") == 0) {
    open_flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
  } else {
    enif_free(path);
    return enif_make_badarg(env);
  }

  fd = open(path, open_flags);
  enif_free(path);

  if (fd < 0) {
    const char *reason;

    if (errno == ENOENT) {
      reason = "absent";
    } else if (errno == ELOOP || errno == ENOTDIR) {
      reason = "invalid";
    } else {
      reason = "unavailable";
    }

    return error_tuple(env, reason);
  }

  if (flock(fd, operation) != 0) {
    int reason = errno;
    (void)close(fd);
    return error_tuple(env,
                       reason == EWOULDBLOCK || reason == EAGAIN ? "busy"
                                                                  : "unavailable");
  }

  resource = enif_alloc_resource(lock_resource_type, sizeof(lock_resource));

  if (resource == NULL) {
    (void)flock(fd, LOCK_UN);
    (void)close(fd);
    return error_tuple(env, "unavailable");
  }

  resource->fd = fd;
  handle = enif_make_resource(env, resource);
  enif_release_resource(resource);
  return enif_make_tuple2(env, atom(env, "ok"), handle);
}

static ERL_NIF_TERM release_lock(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  lock_resource *resource;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], lock_resource_type, (void **)&resource)) {
    return enif_make_badarg(env);
  }

  close_lock(resource);
  return atom(env, "ok");
}

static ERL_NIF_TERM rename_noreplace(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  char *source = NULL;
  char *destination = NULL;
  int result;

  if (argc != 2 || !path_argument(env, argv[0], &source) ||
      !path_argument(env, argv[1], &destination)) {
    if (source != NULL) {
      enif_free(source);
    }

    if (destination != NULL) {
      enif_free(destination);
    }

    return enif_make_badarg(env);
  }

#if defined(__APPLE__)
  result = renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, RENAME_EXCL);
#elif defined(__linux__)
  result = renameat2(AT_FDCWD, source, AT_FDCWD, destination,
                     RENAME_NOREPLACE);
#else
#error "cursor signing requires an atomic no-replace rename primitive"
#endif

  enif_free(source);
  enif_free(destination);

  if (result == 0) {
    return atom(env, "ok");
  }

  return error_tuple(env, errno == EEXIST ? "exists" : "unavailable");
}

static int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM load_info) {
  ErlNifResourceFlags flags =
      ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;

  (void)private_data;
  (void)load_info;

  lock_resource_type = enif_open_resource_type(
      env, NULL, "cursor_signing_lock", lock_destructor, flags, NULL);
  return lock_resource_type == NULL ? -1 : 0;
}

static ErlNifFunc functions[] = {
    {"acquire", 3, acquire_lock, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"release", 1, release_lock, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"rename_noreplace", 2, rename_noreplace, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Tightbeam.CursorSigning.Native, functions, load, NULL, NULL,
             NULL)
