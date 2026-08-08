#include "OKQuickJSBridge.h"

#include "quickjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct OKQJSRuntime {
    JSRuntime *runtime;
    JSContext *context;
    uint64_t deadline_nanoseconds;
    OKQJSRequestCallback request_callback;
    OKQJSModuleCallback module_callback;
    OKQJSLogCallback log_callback;
    void *callback_opaque;
};

static uint64_t monotonic_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0;
    }
    return ((uint64_t)value.tv_sec * 1000000000ULL) + (uint64_t)value.tv_nsec;
}

static char *copy_string(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t count = strlen(value);
    char *copy = malloc(count + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, count + 1);
    return copy;
}

static void replace_error(char **error_message, const char *value) {
    if (error_message == NULL) {
        return;
    }
    free(*error_message);
    *error_message = copy_string(value != NULL ? value : "Unknown QuickJS error");
}

static int interrupt_handler(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    OKQJSRuntime *state = opaque;
    if (state == NULL || state->deadline_nanoseconds == 0) {
        return 0;
    }
    return monotonic_nanoseconds() >= state->deadline_nanoseconds;
}

static void set_deadline(OKQJSRuntime *state, uint64_t timeout_milliseconds) {
    uint64_t timeout = timeout_milliseconds == 0 ? 1 : timeout_milliseconds;
    uint64_t now = monotonic_nanoseconds();
    uint64_t delta = timeout > UINT64_MAX / 1000000ULL
        ? UINT64_MAX
        : timeout * 1000000ULL;
    state->deadline_nanoseconds = now > UINT64_MAX - delta
        ? UINT64_MAX
        : now + delta;
}

static JSValue resolve_promise(
    OKQJSRuntime *state,
    JSValue value,
    char **error_message
);

static char *exception_message(JSContext *context) {
    JSValue exception = JS_GetException(context);
    const char *message = JS_ToCString(context, exception);
    JSValue stack = JS_GetPropertyStr(context, exception, "stack");
    const char *stack_text = JS_IsUndefined(stack) ? NULL : JS_ToCString(context, stack);

    const char *selected = stack_text != NULL && stack_text[0] != '\0'
        ? stack_text
        : message;
    char *copy = copy_string(selected != NULL ? selected : "QuickJS exception");

    if (stack_text != NULL) {
        JS_FreeCString(context, stack_text);
    }
    JS_FreeValue(context, stack);
    if (message != NULL) {
        JS_FreeCString(context, message);
    }
    JS_FreeValue(context, exception);
    return copy;
}

static JSModuleDef *host_module_loader(
    JSContext *context,
    const char *module_name,
    void *opaque
) {
    OKQJSRuntime *state = opaque;
    if (state == NULL || state->module_callback == NULL) {
        JS_ThrowReferenceError(context, "Module loader is unavailable");
        return NULL;
    }

    char *callback_error = NULL;
    char *source = state->module_callback(
        state->callback_opaque,
        module_name,
        &callback_error
    );
    if (callback_error != NULL) {
        JS_ThrowReferenceError(
            context,
            "Unable to load module '%s': %s",
            module_name,
            callback_error
        );
        free(callback_error);
        free(source);
        return NULL;
    }
    if (source == NULL) {
        JS_ThrowReferenceError(
            context,
            "Module loader returned no source for '%s'",
            module_name
        );
        return NULL;
    }

    JSValue compiled = JS_Eval(
        context,
        source,
        strlen(source),
        module_name,
        JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY
    );
    free(source);
    if (JS_IsException(compiled)) {
        return NULL;
    }
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    JS_FreeValue(context, compiled);
    return module;
}

static int install_cheerio_parser(
    OKQJSRuntime *state,
    char **error_message
) {
    static const char *parser_module =
        "import cheerio from 'assets://js/lib/cheerio.min.js';"
        "const splitRule=(rule)=>String(rule||'').split('&&').filter(Boolean);"
        "const selection=(html,rule,withOperation)=>{"
        "const $=cheerio.load(String(html||''));const parts=splitRule(rule);"
        "let operation='';"
        "if(withOperation&&parts.length){"
        "const last=parts[parts.length-1];"
        "if(/^(Text|Html)$/i.test(last)||/^[A-Za-z_:][-A-Za-z0-9_:.]*$/.test(last)){"
        "operation=parts.pop()}}"
        "const selector=parts.length?parts.join(' '):'body';"
        "return{$,nodes:$(selector),operation}};"
        "globalThis.pdfh=(html,rule)=>{"
        "const value=selection(html,rule,true),node=value.nodes.first();"
        "if(!node.length)return '';"
        "if(/^Text$/i.test(value.operation))return node.text().trim();"
        "if(/^Html$/i.test(value.operation))return node.html()||'';"
        "if(value.operation)return node.attr(value.operation)||'';"
        "return node.text().trim()};"
        "globalThis.pdfa=(html,rule)=>{"
        "const value=selection(html,rule,false),items=[];"
        "value.nodes.each((index,node)=>items.push(value.$.html(node)||''));"
        "return items};"
        "globalThis.pd=(html,rule,base='')=>{"
        "const value=globalThis.pdfh(html,rule);"
        "return value?globalThis.joinUrl(base,value):value};"
        "globalThis.pdfl=(html,rule,textRule,urlRule,base='')=>"
        "globalThis.pdfa(html,rule).map(item=>"
        "globalThis.pdfh(item,textRule)+'$'+globalThis.pd(item,urlRule,base));";

    JSValue result = JS_Eval(
        state->context,
        parser_module,
        strlen(parser_module),
        "<okvideomac-cheerio-parser>",
        JS_EVAL_TYPE_MODULE
    );
    if (!JS_IsException(result)) {
        result = resolve_promise(state, result, error_message);
    }
    if (JS_IsException(result)) {
        if (error_message == NULL || *error_message == NULL) {
            char *message = exception_message(state->context);
            replace_error(error_message, message);
            free(message);
        }
        return -1;
    }
    JS_FreeValue(state->context, result);
    return 0;
}

static JSValue host_log(
    JSContext *context,
    JSValueConst this_value,
    int argument_count,
    JSValueConst *arguments
) {
    (void)this_value;
    OKQJSRuntime *state = JS_GetContextOpaque(context);
    if (state == NULL || state->log_callback == NULL) {
        return JS_UNDEFINED;
    }

    char buffer[4096];
    size_t used = 0;
    buffer[0] = '\0';
    for (int index = 0; index < argument_count && used < sizeof(buffer) - 1; index++) {
        const char *value = JS_ToCString(context, arguments[index]);
        if (value == NULL) {
            continue;
        }
        if (used != 0 && used < sizeof(buffer) - 1) {
            buffer[used++] = ' ';
        }
        size_t available = sizeof(buffer) - used - 1;
        size_t count = strlen(value);
        if (count > available) {
            count = available;
        }
        memcpy(buffer + used, value, count);
        used += count;
        buffer[used] = '\0';
        JS_FreeCString(context, value);
    }
    state->log_callback(state->callback_opaque, buffer);
    return JS_UNDEFINED;
}

static JSValue host_request(
    JSContext *context,
    JSValueConst this_value,
    int argument_count,
    JSValueConst *arguments
) {
    (void)this_value;
    OKQJSRuntime *state = JS_GetContextOpaque(context);
    if (state == NULL || state->request_callback == NULL) {
        return JS_ThrowInternalError(context, "Network bridge is unavailable");
    }
    if (argument_count < 1) {
        return JS_ThrowTypeError(context, "request requires a URL or request object");
    }

    JSValue request_json = JS_JSONStringify(
        context,
        arguments[0],
        JS_UNDEFINED,
        JS_UNDEFINED
    );
    if (JS_IsException(request_json)) {
        return request_json;
    }
    const char *request_text = JS_ToCString(context, request_json);
    JS_FreeValue(context, request_json);
    if (request_text == NULL) {
        return JS_EXCEPTION;
    }

    char *callback_error = NULL;
    char *response_text = state->request_callback(
        state->callback_opaque,
        request_text,
        &callback_error
    );
    JS_FreeCString(context, request_text);

    if (callback_error != NULL) {
        JSValue exception = JS_ThrowInternalError(context, "%s", callback_error);
        free(callback_error);
        free(response_text);
        return exception;
    }
    if (response_text == NULL) {
        return JS_ThrowInternalError(context, "Network bridge returned no response");
    }

    JSValue response = JS_ParseJSON(
        context,
        response_text,
        strlen(response_text),
        "<host-response>"
    );
    free(response_text);
    return response;
}

static JSValue host_delay(
    JSContext *context,
    JSValueConst this_value,
    int argument_count,
    JSValueConst *arguments
) {
    (void)this_value;
    int64_t milliseconds = 0;
    if (argument_count > 0 && JS_ToInt64(context, &milliseconds, arguments[0]) < 0) {
        return JS_EXCEPTION;
    }
    if (milliseconds < 0) {
        milliseconds = 0;
    }
    if (milliseconds > 5000) {
        milliseconds = 5000;
    }
    struct timespec requested = {
        .tv_sec = (time_t)(milliseconds / 1000),
        .tv_nsec = (long)((milliseconds % 1000) * 1000000)
    };
    while (nanosleep(&requested, &requested) != 0) {
        if (interrupt_handler(NULL, JS_GetContextOpaque(context))) {
            return JS_ThrowInternalError(context, "Execution interrupted");
        }
    }
    return JS_UNDEFINED;
}

static int install_host_api(OKQJSRuntime *state, char **error_message) {
    JSContext *context = state->context;
    JSValue global = JS_GetGlobalObject(context);
    JS_SetPropertyStr(
        context,
        global,
        "__ok_request",
        JS_NewCFunction(context, host_request, "__ok_request", 1)
    );
    JS_SetPropertyStr(
        context,
        global,
        "__ok_log",
        JS_NewCFunction(context, host_log, "__ok_log", 1)
    );
    JS_SetPropertyStr(
        context,
        global,
        "__ok_delay",
        JS_NewCFunction(context, host_delay, "__ok_delay", 1)
    );
    JS_FreeValue(context, global);

    static const char *prelude =
        "(() => {"
        "const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';"
        "globalThis.console={log:(...v)=>__ok_log(...v),info:(...v)=>__ok_log(...v),"
        "warn:(...v)=>__ok_log(...v),error:(...v)=>__ok_log(...v)};"
        "globalThis.req=(url,options={})=>__ok_request("
        "Object.assign({},options,{url:String(url)}));"
        "globalThis._http=(url,options={})=>{"
        "const response=globalThis.req(url,options);"
        "if(typeof options.complete==='function'){options.complete(response);return undefined}"
        "return response};"
        "globalThis.request=(value,options={})=>__ok_request("
        "typeof value==='string'?Object.assign({url:value},options):value);"
        "globalThis.fetch=globalThis.request;"
        "globalThis.joinUrl=(parent,child)=>{"
        "parent=String(parent||'');child=String(child||'');"
        "if(/^[A-Za-z][A-Za-z0-9+.-]*:/.test(child))return child;"
        "if(child.startsWith('//')){const m=parent.match(/^([A-Za-z][A-Za-z0-9+.-]*:)/);"
        "return(m?m[1]:'https:')+child}"
        "const origin=(parent.match(/^([A-Za-z][A-Za-z0-9+.-]*:\\/\\/[^/]+)/)||[])[1]||'';"
        "let path=child.startsWith('/')?child:"
        "(parent.replace(/[?#].*$/,'').replace(/\\/[^/]*$/,'/')+child).replace(origin,'');"
        "const out=[];for(const part of path.split('/')){"
        "if(!part||part==='.')continue;if(part==='..'){out.pop()}else{out.push(part)}}"
        "return origin+'/'+out.join('/')};"
        "globalThis.getProxy=()=> 'http://127.0.0.1:9978/proxy?do=js';"
        "const localValues=new Map();"
        "globalThis.local={"
        "get:(rule,key)=>localValues.get(String(rule||'')+'\\0'+String(key||''))||'',"
        "set:(rule,key,value)=>{localValues.set(String(rule||'')+'\\0'+String(key||''),String(value||''))},"
        "delete:(rule,key)=>{localValues.delete(String(rule||'')+'\\0'+String(key||''))}};"
        "globalThis.delay=(milliseconds)=>{__ok_delay(milliseconds);return Promise.resolve();};"
        "globalThis.base64Encode=(input)=>{"
        "let value=unescape(encodeURIComponent(String(input))),out='',i=0;"
        "while(i<value.length){let a=value.charCodeAt(i++),b=value.charCodeAt(i++),c=value.charCodeAt(i++);"
        "let x=a>>2,y=((a&3)<<4)|(b>>4),z=((b&15)<<2)|(c>>6),w=c&63;"
        "if(Number.isNaN(b)){z=w=64}else if(Number.isNaN(c)){w=64}"
        "out+=alphabet[x]+alphabet[y]+alphabet[z]+alphabet[w]}return out};"
        "globalThis.base64Decode=(input)=>{"
        "let value=String(input).replace(/[^A-Za-z0-9+/=]/g,''),out='',i=0;"
        "while(i<value.length){let x=alphabet.indexOf(value[i++]),y=alphabet.indexOf(value[i++]),"
        "z=alphabet.indexOf(value[i++]),w=alphabet.indexOf(value[i++]);"
        "let a=(x<<2)|(y>>4),b=((y&15)<<4)|(z>>2),c=((z&3)<<6)|w;"
        "out+=String.fromCharCode(a);if(z!==64)out+=String.fromCharCode(b);"
        "if(w!==64)out+=String.fromCharCode(c)}return decodeURIComponent(escape(out))};"
        "globalThis.urlEncode=(input)=>encodeURIComponent(String(input));"
        "})();";
    JSValue result = JS_Eval(
        context,
        prelude,
        strlen(prelude),
        "<okvideomac-host>",
        JS_EVAL_TYPE_GLOBAL
    );
    if (JS_IsException(result)) {
        char *message = exception_message(context);
        replace_error(error_message, message);
        free(message);
        return -1;
    }
    JS_FreeValue(context, result);
    return 0;
}

OKQJSRuntime *okqjs_create(
    size_t memory_limit_bytes,
    OKQJSRequestCallback request_callback,
    OKQJSModuleCallback module_callback,
    OKQJSLogCallback log_callback,
    void *callback_opaque,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    OKQJSRuntime *state = calloc(1, sizeof(OKQJSRuntime));
    if (state == NULL) {
        replace_error(error_message, "Unable to allocate QuickJS bridge");
        return NULL;
    }
    state->request_callback = request_callback;
    state->module_callback = module_callback;
    state->log_callback = log_callback;
    state->callback_opaque = callback_opaque;
    state->runtime = JS_NewRuntime();
    if (state->runtime == NULL) {
        replace_error(error_message, "Unable to create QuickJS runtime");
        free(state);
        return NULL;
    }
    JS_SetMemoryLimit(
        state->runtime,
        memory_limit_bytes == 0 ? 64 * 1024 * 1024 : memory_limit_bytes
    );
    JS_SetMaxStackSize(state->runtime, 1024 * 1024);
    JS_SetInterruptHandler(state->runtime, interrupt_handler, state);
    JS_SetModuleLoaderFunc(
        state->runtime,
        NULL,
        host_module_loader,
        state
    );
    state->context = JS_NewContext(state->runtime);
    if (state->context == NULL) {
        replace_error(error_message, "Unable to create QuickJS context");
        JS_FreeRuntime(state->runtime);
        free(state);
        return NULL;
    }
    JS_SetContextOpaque(state->context, state);
    if (install_host_api(state, error_message) != 0) {
        okqjs_destroy(state);
        return NULL;
    }
    return state;
}

int okqjs_load(
    OKQJSRuntime *state,
    const char *script,
    const char *source_name,
    uint64_t timeout_milliseconds,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (state == NULL || script == NULL) {
        replace_error(error_message, "QuickJS runtime or script is missing");
        return -1;
    }
    set_deadline(state, timeout_milliseconds);
    const char *name = source_name != NULL ? source_name : "<spider>";
    size_t script_length = strlen(script);
    int is_module = JS_DetectModule(script, script_length);
    if (is_module
        && strstr(script, "assets://js/lib/cheerio.min.js") != NULL
        && install_cheerio_parser(state, error_message) != 0) {
        state->deadline_nanoseconds = 0;
        return -1;
    }
    JSValue result = JS_Eval(
        state->context,
        script,
        script_length,
        name,
        is_module ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL
    );
    if (is_module && !JS_IsException(result)) {
        result = resolve_promise(state, result, error_message);
    }
    if (JS_IsException(result)) {
        if (error_message == NULL || *error_message == NULL) {
            char *message = exception_message(state->context);
            replace_error(error_message, message);
            free(message);
        }
        state->deadline_nanoseconds = 0;
        return -1;
    }
    JS_FreeValue(state->context, result);

    if (is_module) {
        size_t wrapper_capacity = strlen(name) * 2 + 512;
        char *wrapper = malloc(wrapper_capacity);
        if (wrapper == NULL) {
            state->deadline_nanoseconds = 0;
            replace_error(error_message, "Unable to allocate Spider module wrapper");
            return -1;
        }
        int count = snprintf(
            wrapper,
            wrapper_capacity,
            "import * as __ok_module from \"%s\";"
            "const __ok_export=__ok_module.__jsEvalReturn"
            "?__ok_module.__jsEvalReturn():__ok_module.default;"
            "globalThis.__JS_SPIDER__="
            "typeof __ok_export==='function'?__ok_export():__ok_export;"
            "globalThis.spider=globalThis.__JS_SPIDER__;",
            name
        );
        if (count < 0 || (size_t)count >= wrapper_capacity) {
            free(wrapper);
            state->deadline_nanoseconds = 0;
            replace_error(error_message, "Spider module URL is too long");
            return -1;
        }
        result = JS_Eval(
            state->context,
            wrapper,
            (size_t)count,
            "<okvideomac-spider-wrapper>",
            JS_EVAL_TYPE_MODULE
        );
        free(wrapper);
        if (!JS_IsException(result)) {
            result = resolve_promise(state, result, error_message);
        }
        if (JS_IsException(result)) {
            if (error_message == NULL || *error_message == NULL) {
                char *message = exception_message(state->context);
                replace_error(error_message, message);
                free(message);
            }
            state->deadline_nanoseconds = 0;
            return -1;
        }
        JS_FreeValue(state->context, result);
    }
    state->deadline_nanoseconds = 0;
    return 0;
}

static JSValue resolve_promise(
    OKQJSRuntime *state,
    JSValue value,
    char **error_message
) {
    JSContext *context = state->context;
    JSValue global = JS_GetGlobalObject(context);
    JSValue promise_constructor = JS_GetPropertyStr(context, global, "Promise");
    JSValue resolve = JS_GetPropertyStr(context, promise_constructor, "resolve");
    JSValue promise = JS_Call(context, resolve, promise_constructor, 1, &value);
    JS_FreeValue(context, resolve);
    JS_FreeValue(context, promise_constructor);
    JS_FreeValue(context, global);
    JS_FreeValue(context, value);
    if (JS_IsException(promise)) {
        return promise;
    }

    while (JS_PromiseState(context, promise) == JS_PROMISE_PENDING) {
        JSContext *job_context = NULL;
        int result = JS_ExecutePendingJob(state->runtime, &job_context);
        if (result < 0) {
            JS_FreeValue(context, promise);
            return JS_EXCEPTION;
        }
        if (result == 0) {
            JS_FreeValue(context, promise);
            replace_error(error_message, "Spider Promise remained pending without a scheduled job");
            return JS_EXCEPTION;
        }
    }
    JSValue resolved = JS_PromiseResult(context, promise);
    if (JS_PromiseState(context, promise) == JS_PROMISE_REJECTED) {
        const char *message = JS_ToCString(context, resolved);
        replace_error(error_message, message);
        if (message != NULL) {
            JS_FreeCString(context, message);
        }
        JS_FreeValue(context, resolved);
        JS_FreeValue(context, promise);
        return JS_EXCEPTION;
    }
    JS_FreeValue(context, promise);
    return resolved;
}

char *okqjs_invoke(
    OKQJSRuntime *state,
    const char *method,
    const char *arguments_json,
    uint64_t timeout_milliseconds,
    char **error_message
) {
    if (error_message != NULL) {
        *error_message = NULL;
    }
    if (state == NULL || method == NULL || arguments_json == NULL) {
        replace_error(error_message, "QuickJS invocation arguments are missing");
        return NULL;
    }

    set_deadline(state, timeout_milliseconds);
    JSContext *context = state->context;
    JSValue global = JS_GetGlobalObject(context);
    JSValue spider = JS_GetPropertyStr(context, global, "spider");
    if (JS_IsUndefined(spider) || JS_IsNull(spider)) {
        JS_FreeValue(context, spider);
        spider = JS_GetPropertyStr(context, global, "__JS_SPIDER__");
    }
    JS_FreeValue(context, global);
    if (!JS_IsObject(spider)) {
        JS_FreeValue(context, spider);
        state->deadline_nanoseconds = 0;
        replace_error(error_message, "Script must expose globalThis.spider");
        return NULL;
    }

    JSValue function = JS_GetPropertyStr(context, spider, method);
    if (!JS_IsFunction(context, function)) {
        JS_FreeValue(context, function);
        JS_FreeValue(context, spider);
        state->deadline_nanoseconds = 0;
        replace_error(error_message, "Spider method is missing");
        return NULL;
    }

    JSValue arguments = JS_ParseJSON(
        context,
        arguments_json,
        strlen(arguments_json),
        "<spider-arguments>"
    );
    if (JS_IsException(arguments) || !JS_IsArray(context, arguments)) {
        if (!JS_IsException(arguments)) {
            JS_FreeValue(context, arguments);
        }
        JS_FreeValue(context, function);
        JS_FreeValue(context, spider);
        state->deadline_nanoseconds = 0;
        replace_error(error_message, "Spider arguments must be a JSON array");
        return NULL;
    }

    uint32_t count = 0;
    JSValue length = JS_GetPropertyStr(context, arguments, "length");
    JS_ToUint32(context, &count, length);
    JS_FreeValue(context, length);
    JSValue *values = count == 0 ? NULL : calloc(count, sizeof(JSValue));
    if (count != 0 && values == NULL) {
        JS_FreeValue(context, arguments);
        JS_FreeValue(context, function);
        JS_FreeValue(context, spider);
        state->deadline_nanoseconds = 0;
        replace_error(error_message, "Unable to allocate Spider arguments");
        return NULL;
    }
    for (uint32_t index = 0; index < count; index++) {
        values[index] = JS_GetPropertyUint32(context, arguments, index);
    }

    JSValue result = JS_Call(context, function, spider, (int)count, values);
    for (uint32_t index = 0; index < count; index++) {
        JS_FreeValue(context, values[index]);
    }
    free(values);
    JS_FreeValue(context, arguments);
    JS_FreeValue(context, function);
    JS_FreeValue(context, spider);

    if (!JS_IsException(result)) {
        result = resolve_promise(state, result, error_message);
    }
    state->deadline_nanoseconds = 0;
    if (JS_IsException(result)) {
        if (error_message == NULL || *error_message == NULL) {
            char *message = exception_message(context);
            replace_error(error_message, message);
            free(message);
        }
        return NULL;
    }

    JSValue json = JS_IsUndefined(result)
        ? JS_NewString(context, "null")
        : JS_JSONStringify(context, result, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(context, result);
    if (JS_IsException(json)) {
        char *message = exception_message(context);
        replace_error(error_message, message);
        free(message);
        return NULL;
    }
    const char *text = JS_ToCString(context, json);
    char *copy = copy_string(text != NULL ? text : "null");
    if (text != NULL) {
        JS_FreeCString(context, text);
    }
    JS_FreeValue(context, json);
    if (copy == NULL) {
        replace_error(error_message, "Unable to copy Spider result");
    }
    return copy;
}

void okqjs_destroy(OKQJSRuntime *state) {
    if (state == NULL) {
        return;
    }
    if (state->context != NULL) {
        JS_SetContextOpaque(state->context, NULL);
        JS_FreeContext(state->context);
    }
    if (state->runtime != NULL) {
        JS_FreeRuntime(state->runtime);
    }
    free(state);
}

void okqjs_free_string(char *value) {
    free(value);
}

const char *okqjs_version(void) {
    return "2025-09-13-2";
}
