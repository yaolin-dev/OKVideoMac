#ifndef OK_QUICKJS_BRIDGE_H
#define OK_QUICKJS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OKQJSRuntime OKQJSRuntime;

typedef char *(*OKQJSRequestCallback)(
    void *opaque,
    const char *request_json,
    char **error_message
);

typedef char *(*OKQJSModuleCallback)(
    void *opaque,
    const char *module_name,
    char **error_message
);

typedef void (*OKQJSLogCallback)(
    void *opaque,
    const char *message
);

OKQJSRuntime *okqjs_create(
    size_t memory_limit_bytes,
    OKQJSRequestCallback request_callback,
    OKQJSModuleCallback module_callback,
    OKQJSLogCallback log_callback,
    void *callback_opaque,
    char **error_message
);

int okqjs_load(
    OKQJSRuntime *runtime,
    const char *script,
    const char *source_name,
    uint64_t timeout_milliseconds,
    char **error_message
);

char *okqjs_invoke(
    OKQJSRuntime *runtime,
    const char *method,
    const char *arguments_json,
    uint64_t timeout_milliseconds,
    char **error_message
);

void okqjs_destroy(OKQJSRuntime *runtime);
void okqjs_free_string(char *value);
const char *okqjs_version(void);

#ifdef __cplusplus
}
#endif

#endif
