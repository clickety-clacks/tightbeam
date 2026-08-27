#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define READ_CHUNK (64U * 1024U)

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__DragonFly__) ||    \
    defined(__OpenBSD__) || defined(__NetBSD__)
#define STAT_MTIME_NSEC(value) ((value).st_mtimespec.tv_nsec)
#define STAT_CTIME_NSEC(value) ((value).st_ctimespec.tv_nsec)
#else
#define STAT_MTIME_NSEC(value) ((value).st_mtim.tv_nsec)
#define STAT_CTIME_NSEC(value) ((value).st_ctim.tv_nsec)
#endif

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) {
  return enif_make_atom(env, name);
}

static ERL_NIF_TERM error(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, atom(env, "error"), atom(env, reason));
}

static void wipe(void *memory, size_t size) {
  volatile unsigned char *bytes = memory;
  while (size-- > 0) {
    *bytes++ = 0;
  }
}

static int same_snapshot(const struct stat *left, const struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
         left->st_mode == right->st_mode && left->st_uid == right->st_uid &&
         left->st_size == right->st_size && left->st_mtime == right->st_mtime &&
         STAT_MTIME_NSEC(*left) == STAT_MTIME_NSEC(*right) &&
         left->st_ctime == right->st_ctime &&
         STAT_CTIME_NSEC(*left) == STAT_CTIME_NSEC(*right);
}

static ERL_NIF_TERM read_keyring(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  ErlNifBinary encoded_directory;
  char *directory = NULL;
  ErlNifUInt64 expected_uid;
  int directory_fd = -1;
  int file_fd = -1;
  unsigned char *buffer = NULL;
  size_t capacity = READ_CHUNK;
  size_t length = 0;
  struct stat directory_stat;
  struct stat before;
  struct stat after;
  ERL_NIF_TERM result;

  if (argc != 2 ||
      !enif_inspect_iolist_as_binary(env, argv[0], &encoded_directory) ||
      encoded_directory.size == 0 ||
      memchr(encoded_directory.data, '\0', encoded_directory.size) != NULL ||
      !enif_get_uint64(env, argv[1], &expected_uid) ||
      expected_uid > UINT32_MAX) {
    return enif_make_badarg(env);
  }

  directory = malloc(encoded_directory.size + 1);
  if (directory == NULL) {
    return error(env, "read_failed");
  }
  memcpy(directory, encoded_directory.data, encoded_directory.size);
  directory[encoded_directory.size] = '\0';

  directory_fd =
      open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (directory_fd < 0 || fstat(directory_fd, &directory_stat) != 0 ||
      !S_ISDIR(directory_stat.st_mode) ||
      directory_stat.st_uid != (uid_t)expected_uid ||
      (directory_stat.st_mode & 07777) != 0700) {
    result = error(env, "unsafe_directory");
    goto done;
  }

  file_fd = openat(directory_fd, "visitor-keyring-v1.json",
                   O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (file_fd < 0 || fstat(file_fd, &before) != 0 ||
      !S_ISREG(before.st_mode) || before.st_uid != (uid_t)expected_uid ||
      (before.st_mode & 07777) != 0600) {
    result = error(env, "unsafe_file");
    goto done;
  }

  buffer = malloc(capacity);
  if (buffer == NULL) {
    result = error(env, "read_failed");
    goto done;
  }

  for (;;) {
    if (length == capacity) {
      size_t next_capacity;
      unsigned char *grown;

      if (capacity > SIZE_MAX / 2) {
        result = error(env, "read_failed");
        goto done;
      }
      next_capacity = capacity * 2;
      grown = realloc(buffer, next_capacity);
      if (grown == NULL) {
        result = error(env, "read_failed");
        goto done;
      }
      buffer = grown;
      capacity = next_capacity;
    }

    ssize_t count = read(file_fd, buffer + length, capacity - length);
    if (count > 0) {
      length += (size_t)count;
      continue;
    }
    if (count == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    result = error(env, "read_failed");
    goto done;
  }

  if (fstat(file_fd, &after) != 0 || !same_snapshot(&before, &after) ||
      after.st_size < 0 || (uintmax_t)after.st_size != (uintmax_t)length) {
    result = error(env, "changed_during_read");
    goto done;
  }

  {
    ERL_NIF_TERM binary_term;
    unsigned char *binary = enif_make_new_binary(env, length, &binary_term);
    if (binary == NULL && length != 0) {
      result = error(env, "read_failed");
      goto done;
    }
    if (length != 0) {
      memcpy(binary, buffer, length);
    }
    result = enif_make_tuple2(env, atom(env, "ok"), binary_term);
  }

done:
  if (directory != NULL) {
    free(directory);
  }
  if (buffer != NULL) {
    wipe(buffer, capacity);
    free(buffer);
  }
  if (file_fd >= 0) {
    close(file_fd);
  }
  if (directory_fd >= 0) {
    close(directory_fd);
  }
  return result;
}

static ErlNifFunc functions[] = {
    {"read", 2, read_keyring, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.Tightbeam.Visitor.Keyring.Native, functions, NULL, NULL,
             NULL, NULL)
