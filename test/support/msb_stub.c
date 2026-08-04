/*
 * A stand-in for libmicrosandbox_go_ffi, built at test time.
 *
 * The real library boots microVMs; this one implements the same C ABI so the
 * fiddle bindings — argument marshalling, the output buffer, the error/free
 * convention, cancellation tokens — can be tested on a machine with no
 * microsandbox installed and no KVM.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t next_cancel = 1;
static int cancelled_flag = 0;

void msb_free_string(char *ptr) { free(ptr); }

uint64_t msb_cancel_alloc(void) { return next_cancel++; }
void msb_cancel_trigger(uint64_t id) { (void)id; cancelled_flag = 1; }
void msb_cancel_unregister(uint64_t id) { (void)id; }

static char *fill(unsigned char *buf, size_t len, const char *json) {
  size_t n = strlen(json);
  if (n + 1 > len) return strdup("{\"kind\":\"internal\",\"message\":\"buffer too small\"}");
  memcpy(buf, json, n + 1);
  return NULL;
}

char *msb_version(unsigned char *buf, size_t len) {
  return fill(buf, len, "{\"version\":\"stub-0.1\"}");
}

char *msb_sandbox_create(uint64_t cancel, const char *name, const char *opts_json,
                         unsigned char *buf, size_t len) {
  (void)cancel;
  char json[4096];
  snprintf(json, sizeof(json),
           "{\"handle\":42,\"name\":\"%s\",\"opts\":%s}", name ? name : "", opts_json ? opts_json : "null");
  return fill(buf, len, json);
}

char *msb_sandbox_connect(uint64_t cancel, const char *name, unsigned char *buf, size_t len) {
  (void)cancel; (void)name;
  return fill(buf, len, "{\"handle\":42}");
}

/* echoes the command back, base64 of "ok\n" as stdout, so the decode path is exercised */
char *msb_sandbox_exec(uint64_t cancel, uint64_t handle, const char *cmd,
                       const char *opts_json, unsigned char *buf, size_t len) {
  (void)cancel;
  if (strstr(cmd ? cmd : "", "boom") != NULL || strstr(opts_json ? opts_json : "", "boom") != NULL) {
    return strdup("{\"kind\":\"exec_failed\",\"message\":\"command exploded\"}");
  }
  char json[8192];
  snprintf(json, sizeof(json),
           "{\"stdout_b64\":\"b2sK\",\"stderr_b64\":\"\",\"exit_code\":0,"
           "\"handle\":%llu,\"cmd\":\"%s\",\"opts\":%s}",
           (unsigned long long)handle, cmd ? cmd : "", opts_json ? opts_json : "null");
  return fill(buf, len, json);
}

char *msb_sandbox_stop(uint64_t cancel, uint64_t handle, uint64_t timeout_ms,
                       unsigned char *buf, size_t len) {
  (void)cancel; (void)handle; (void)timeout_ms;
  return fill(buf, len, "{\"ok\":true}");
}

char *msb_sandbox_detach(uint64_t cancel, uint64_t handle, unsigned char *buf, size_t len) {
  (void)cancel; (void)handle;
  return fill(buf, len, "{\"ok\":true}");
}

char *msb_fs_read(uint64_t cancel, uint64_t handle, const char *path,
                  unsigned char *buf, size_t len) {
  (void)cancel; (void)handle;
  char json[4096];
  /* base64 of "guest file contents" */
  snprintf(json, sizeof(json), "{\"data_b64\":\"Z3Vlc3QgZmlsZSBjb250ZW50cw==\",\"path\":\"%s\"}",
           path ? path : "");
  return fill(buf, len, json);
}

char *msb_fs_write(uint64_t cancel, uint64_t handle, const char *path, const char *data_b64,
                   unsigned char *buf, size_t len) {
  (void)cancel; (void)handle;
  char json[8192];
  snprintf(json, sizeof(json), "{\"ok\":true,\"path\":\"%s\",\"data_b64\":\"%s\"}",
           path ? path : "", data_b64 ? data_b64 : "");
  return fill(buf, len, json);
}

char *msb_fs_copy_from_host(uint64_t c, uint64_t h, const char *a, const char *b,
                            unsigned char *buf, size_t len) {
  (void)c; (void)h; (void)a; (void)b;
  return fill(buf, len, "{\"ok\":true}");
}

char *msb_fs_copy_to_host(uint64_t c, uint64_t h, const char *a, const char *b,
                          unsigned char *buf, size_t len) {
  (void)c; (void)h; (void)a; (void)b;
  return fill(buf, len, "{\"ok\":true}");
}
