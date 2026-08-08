#include "OKQuickJSBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *duplicate(const char *value) {
    size_t count = strlen(value);
    char *copy = malloc(count + 1);
    memcpy(copy, value, count + 1);
    return copy;
}

static char *request_callback(void *opaque, const char *request, char **error) {
    (void)opaque;
    (void)error;
    if (strstr(request, "example.invalid") == NULL) {
        *error = duplicate("Unexpected request");
        return NULL;
    }
    return duplicate(
        "{\"code\":200,\"headers\":{\"Content-Type\":\"text/plain\"},"
        "\"content\":\"fixture response\"}"
    );
}

static char *module_callback(void *opaque, const char *module_name, char **error) {
    (void)opaque;
    if (strcmp(module_name, "fixture-dependency.js") != 0) {
        *error = duplicate("Unexpected module");
        return NULL;
    }
    return duplicate("export const suffix=' module';");
}

static void log_callback(void *opaque, const char *message) {
    (void)opaque;
    fprintf(stderr, "spider-log: %s\n", message);
}

static int require_result(
    OKQJSRuntime *runtime,
    const char *method,
    const char *arguments,
    const char *expected
) {
    char *error = NULL;
    char *result = okqjs_invoke(runtime, method, arguments, 1000, &error);
    if (result == NULL || strcmp(result, expected) != 0) {
        fprintf(
            stderr,
            "%s failed: result=%s error=%s\n",
            method,
            result != NULL ? result : "<null>",
            error != NULL ? error : "<none>"
        );
        okqjs_free_string(result);
        okqjs_free_string(error);
        return 1;
    }
    okqjs_free_string(result);
    okqjs_free_string(error);
    return 0;
}

int main(void) {
    char *error = NULL;
    OKQJSRuntime *runtime = okqjs_create(
        64 * 1024 * 1024,
        request_callback,
        module_callback,
        log_callback,
        NULL,
        &error
    );
    if (runtime == NULL) {
        fprintf(stderr, "create failed: %s\n", error);
        okqjs_free_string(error);
        return 1;
    }

    const char *script =
        "globalThis.spider={"
        "init:(ext)=>({ready:true,ext}),"
        "home:(filter)=>Promise.resolve({filter,encoded:base64Encode('OK影视')}),"
        "search:(keyword)=>({keyword,response:request('https://example.invalid/api').content}),"
        "loop:()=>{while(true){}}"
        "};";
    if (okqjs_load(runtime, script, "smoke.js", 1000, &error) != 0) {
        fprintf(stderr, "load failed: %s\n", error);
        okqjs_free_string(error);
        okqjs_destroy(runtime);
        return 1;
    }
    if (require_result(runtime, "init", "[{\"mode\":\"fixture\"}]",
                       "{\"ready\":true,\"ext\":{\"mode\":\"fixture\"}}") != 0 ||
        require_result(runtime, "home", "[true]",
                       "{\"filter\":true,\"encoded\":\"T0vlvbHop4Y=\"}") != 0 ||
        require_result(runtime, "search", "[\"fixture\"]",
                       "{\"keyword\":\"fixture\",\"response\":\"fixture response\"}") != 0) {
        okqjs_destroy(runtime);
        return 1;
    }

    if (okqjs_load(
            runtime,
            "import {suffix} from './fixture-dependency.js';"
            "export default {home:()=>({value:'ES'+suffix})};",
            "fixture-main.js",
            1000,
            &error
        ) != 0 ||
        require_result(
            runtime,
            "home",
            "[]",
            "{\"value\":\"ES module\"}"
        ) != 0) {
        fprintf(stderr, "module load failed: %s\n", error != NULL ? error : "<none>");
        okqjs_free_string(error);
        okqjs_destroy(runtime);
        return 1;
    }

    char *loop_result = okqjs_invoke(runtime, "loop", "[]", 50, &error);
    if (loop_result != NULL || error == NULL) {
        fprintf(stderr, "interrupt test did not fail\n");
        okqjs_free_string(loop_result);
        okqjs_free_string(error);
        okqjs_destroy(runtime);
        return 1;
    }
    okqjs_free_string(error);
    okqjs_destroy(runtime);
    printf("QuickJS bridge smoke test passed (%s)\n", okqjs_version());
    return 0;
}
