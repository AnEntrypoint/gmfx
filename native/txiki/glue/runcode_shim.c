#include <quickjs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <uv.h>

#include "runcode_shim.h"
#include "txiki_shim.h"

typedef struct FxRun {
    const FxRunCodeHost *host;
    const char *root;
    uint64_t started_ns;
    uint64_t budget_ns;
    unsigned long long budget_ms;
    int deadline_hit;
    int exit_requested;
    int exit_code;
    uv_timer_t timer;
    JSValue gm;
    JSValue require;
} FxRun;

static FxRun *current_run = NULL;

static uint64_t monotonic_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t) now.tv_sec * 1000000000ull + (uint64_t) now.tv_nsec;
}

static unsigned long long remaining_ms(const FxRun *run) {
    uint64_t elapsed = monotonic_ns() - run->started_ns;
    if (elapsed >= run->budget_ns) return 0;
    return (unsigned long long) ((run->budget_ns - elapsed) / 1000000ull);
}

static int interrupt_handler(JSContext *ctx, void *opaque) {
    FxRun *run = opaque;
    (void) ctx;
    if (monotonic_ns() - run->started_ns < run->budget_ns) return 0;
    run->deadline_hit = 1;
    return 1;
}

static void deadline_fired(uv_timer_t *timer) {
    FxRun *run = timer->data;
    run->deadline_hit = 1;
    uv_stop(timer->loop);
}

static char *copy_text(const char *text) {
    size_t length = strlen(text);
    char *copy = malloc(length + 1);
    if (copy != NULL) memcpy(copy, text, length + 1);
    return copy;
}

static char *value_text(JSContext *ctx, JSValueConst value) {
    const char *head = JS_ToCString(ctx, value);
    JSValue stack = JS_UNDEFINED;
    if (JS_IsObject(value)) stack = JS_GetPropertyStr(ctx, value, "stack");
    const char *tail = JS_IsString(stack) ? JS_ToCString(ctx, stack) : NULL;
    const char *lead = head != NULL ? head : "unknown error";
    char *copy = NULL;
    if (tail != NULL && strncmp(tail, lead, strlen(lead)) == 0) {
        copy = copy_text(tail);
    } else if (tail != NULL) {
        size_t lead_length = strlen(lead);
        size_t tail_length = strlen(tail);
        copy = malloc(lead_length + tail_length + 2);
        if (copy != NULL) {
            memcpy(copy, lead, lead_length);
            copy[lead_length] = '\n';
            memcpy(copy + lead_length + 1, tail, tail_length + 1);
        }
    } else {
        copy = copy_text(lead);
    }
    if (tail != NULL) JS_FreeCString(ctx, tail);
    if (head != NULL) JS_FreeCString(ctx, head);
    JS_FreeValue(ctx, stack);
    return copy;
}

static char *pending_error(JSContext *ctx) {
    JSValue exception = JS_GetException(ctx);
    char *text = value_text(ctx, exception);
    JS_FreeValue(ctx, exception);
    return text;
}

static char *collapse_path(JSContext *ctx, const char *path) {
    size_t length = strlen(path);
    char *copy = malloc(length + 1);
    char *out = js_malloc(ctx, length + 2);
    if (copy == NULL || out == NULL) {
        free(copy);
        if (out != NULL) js_free(ctx, out);
        return NULL;
    }
    memcpy(copy, path, length + 1);
    const char *segments[256];
    size_t count = 0;
    char *token = strtok(copy, "/");
    while (token != NULL) {
        if (strcmp(token, "..") == 0) {
            if (count > 0) count--;
        } else if (strcmp(token, ".") != 0 && token[0] != '\0' && count < 256) {
            segments[count++] = token;
        }
        token = strtok(NULL, "/");
    }
    size_t pos = 0;
    out[pos++] = '/';
    for (size_t i = 0; i < count; i++) {
        size_t segment_length = strlen(segments[i]);
        memcpy(out + pos, segments[i], segment_length);
        pos += segment_length;
        if (i + 1 < count) out[pos++] = '/';
    }
    out[pos] = '\0';
    free(copy);
    return out;
}

static char *prefixed(JSContext *ctx, const char *prefix, const char *rest) {
    size_t prefix_length = strlen(prefix);
    size_t rest_length = strlen(rest);
    char *out = js_malloc(ctx, prefix_length + rest_length + 1);
    if (out == NULL) return NULL;
    memcpy(out, prefix, prefix_length);
    memcpy(out + prefix_length, rest, rest_length + 1);
    return out;
}

static char *resolve_bare(JSContext *ctx, FxRun *run, const char *base, const char *name) {
    char *absolute_base = NULL;
    const char *base_path = base;
    if (strncmp(base, "freddie:", 8) != 0 && base[0] != '/') {
        size_t root_length = strlen(run->root);
        size_t base_length = strlen(base);
        absolute_base = malloc(root_length + base_length + 2);
        if (absolute_base == NULL) return NULL;
        memcpy(absolute_base, run->root, root_length);
        absolute_base[root_length] = '/';
        memcpy(absolute_base + root_length + 1, base, base_length + 1);
        base_path = absolute_base;
    }
    size_t request_length = strlen(base_path) + strlen(name) + 16;
    char *request = malloc(request_length);
    if (request == NULL) {
        free(absolute_base);
        return NULL;
    }
    snprintf(request, request_length, "import\n%s\n%s", base_path, name);
    free(absolute_base);
    char *reply = run->host->call(run->host->context, "fx.resolve", request, remaining_ms(run));
    free(request);
    if (reply == NULL) {
        JS_ThrowInternalError(ctx, "the host returned no reply");
        return NULL;
    }
    if (reply[0] == '!') {
        JS_ThrowReferenceError(ctx, "%s", reply + 1);
        free(reply);
        return NULL;
    }
    char *out = js_strdup(ctx, reply);
    free(reply);
    return out;
}

static char *resolve_relative(JSContext *ctx, FxRun *run, const char *base, const char *name) {
    const char *root = run != NULL ? run->root : "/";
    int virtual_base = name[0] != '/' && strncmp(base, "freddie:", 8) == 0;
    char *dir_copy = NULL;
    char *joined = NULL;
    if (name[0] == '/') {
        joined = copy_text(name);
    } else if (virtual_base) {
        const char *base_path = base + 8;
        const char *slash = strrchr(base_path, '/');
        size_t dir_length = slash != NULL ? (size_t) (slash - base_path) : 0;
        size_t name_length = strlen(name);
        joined = malloc(dir_length + name_length + 4);
        if (joined != NULL) {
            joined[0] = '/';
            memcpy(joined + 1, base_path, dir_length);
            joined[1 + dir_length] = '/';
            memcpy(joined + 2 + dir_length, name, name_length + 1);
        }
    } else {
        const char *dir = root;
        if (base[0] == '/') {
            dir_copy = copy_text(base);
            char *slash = strrchr(dir_copy, '/');
            if (slash != NULL && slash != dir_copy) *slash = '\0';
            else if (slash == dir_copy) dir_copy[1] = '\0';
            dir = dir_copy;
        }
        size_t dir_length = strlen(dir);
        size_t name_length = strlen(name);
        joined = malloc(dir_length + name_length + 2);
        if (joined != NULL) {
            memcpy(joined, dir, dir_length);
            joined[dir_length] = '/';
            memcpy(joined + dir_length + 1, name, name_length + 1);
        }
    }
    free(dir_copy);
    if (joined == NULL) return NULL;
    char *normalized = collapse_path(ctx, joined);
    free(joined);
    if (normalized == NULL || !virtual_base) return normalized;
    char *out = prefixed(ctx, "freddie:", normalized + 1);
    js_free(ctx, normalized);
    return out;
}

static char *normalize_module(JSContext *ctx, const char *base, const char *name, void *opaque) {
    (void) opaque;
    if (strncmp(name, "tjs:", 4) == 0 || strncmp(name, "freddie:", 8) == 0 || strncmp(name, "fx:host", 7) == 0) {
        return prefixed(ctx, "", name);
    }
    if (name[0] == '/' || strncmp(name, "./", 2) == 0 || strncmp(name, "../", 3) == 0) {
        return resolve_relative(ctx, current_run, base, name);
    }
    return resolve_bare(ctx, current_run, base, name);
}

static JSModuleDef *compile_source(JSContext *ctx, const char *text, size_t length, const char *name) {
    JSValue compiled = JS_Eval(ctx, text, length, name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(compiled)) return NULL;
    return JS_VALUE_GET_PTR(compiled);
}

static void set_import_meta(JSContext *ctx, JSModuleDef *module, const char *path) {
    JSValue meta = JS_GetImportMeta(ctx, module);
    if (JS_IsException(meta)) return;
    size_t length = strlen(path);
    const char *slash = strrchr(path, '/');
    const char *dir = path;
    size_t dir_length = 1;
    if (slash == NULL) {
        dir = ".";
    } else if (slash == path) {
        dir = "/";
    } else {
        dir_length = (size_t) (slash - path);
    }
    char *url = malloc(length + 8);
    if (url == NULL) {
        JS_FreeValue(ctx, meta);
        return;
    }
    memcpy(url, "file://", 7);
    memcpy(url + 7, path, length + 1);
    JS_DefinePropertyValueStr(ctx, meta, "url", JS_NewString(ctx, url), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, meta, "dirname", JS_NewStringLen(ctx, dir, dir_length), JS_PROP_C_W_E);
    JS_DefinePropertyValueStr(ctx, meta, "filename", JS_NewString(ctx, path), JS_PROP_C_W_E);
    free(url);
    JS_FreeValue(ctx, meta);
}

static JSValue call_cjs_wrap(JSContext *ctx, const char *name, const char *text, size_t length) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue wrap = JS_GetPropertyStr(ctx, global, "__fxCjsWrap");
    JS_FreeValue(ctx, global);
    if (!JS_IsFunction(ctx, wrap)) {
        JS_FreeValue(ctx, wrap);
        return JS_NULL;
    }
    JSValue args[2] = { JS_NewString(ctx, name), JS_NewStringLen(ctx, text, length) };
    JSValue result = JS_Call(ctx, wrap, JS_UNDEFINED, 2, args);
    JS_FreeValue(ctx, wrap);
    JS_FreeValue(ctx, args[0]);
    JS_FreeValue(ctx, args[1]);
    return result;
}

static char *rewrite_hot(const char *text, size_t length, const char *name, size_t *out_length) {
    static const char needle[] = "import.meta.hot";
    static const char alias[] = "__fxHot";
    static const char prologue_head[] = "import { hotFor as __fxHotFor } from 'fx:host/loader'\nconst __fxHot = __fxHotFor(\"";
    static const char prologue_tail[] = "\")\n";
    const size_t needle_length = sizeof(needle) - 1;
    const size_t alias_length = sizeof(alias) - 1;
    size_t count = 0;
    const char *scan = text;
    while ((scan = strstr(scan, needle)) != NULL) {
        count++;
        scan += needle_length;
    }
    if (count == 0) return NULL;
    const size_t name_length = strlen(name);
    const size_t head_length = sizeof(prologue_head) - 1;
    const size_t tail_length = sizeof(prologue_tail) - 1;
    const size_t total = head_length + name_length + tail_length + length - count * needle_length + count * alias_length + 1;
    char *out = malloc(total);
    if (out == NULL) return NULL;
    char *dest = out;
    memcpy(dest, prologue_head, head_length);
    dest += head_length;
    memcpy(dest, name, name_length);
    dest += name_length;
    memcpy(dest, prologue_tail, tail_length);
    dest += tail_length;
    const char *cursor = text;
    const char *match;
    while ((match = strstr(cursor, needle)) != NULL) {
        const size_t prefix = (size_t) (match - cursor);
        memcpy(dest, cursor, prefix);
        dest += prefix;
        memcpy(dest, alias, alias_length);
        dest += alias_length;
        cursor = match + needle_length;
    }
    const size_t rest = length - (size_t) (cursor - text);
    memcpy(dest, cursor, rest);
    dest += rest;
    *dest = '\0';
    *out_length = (size_t) (dest - out);
    return out;
}

static JSModuleDef *load_module(JSContext *ctx, const char *name, void *opaque) {
    FxRun *run = current_run;
    (void) opaque;
    if (strncmp(name, "tjs:", 4) == 0) return gm_txiki_load_builtin(ctx, name);
    if (strncmp(name, "freddie:", 8) == 0 || strncmp(name, "fx:host", 7) == 0) {
        size_t length = 0;
        const char *text = run->host->embedded(run->host->context, name, &length);
        if (text == NULL) {
            JS_ThrowReferenceError(ctx, "could not load module '%s'", name);
            return NULL;
        }
        return compile_source(ctx, text, length, name);
    }
    FILE *file = fopen(name, "rb");
    if (file == NULL) {
        JS_ThrowReferenceError(ctx, "could not load module '%s'", name);
        return NULL;
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    char *text = size >= 0 ? malloc((size_t) size + 1) : NULL;
    size_t got = text != NULL ? fread(text, 1, (size_t) size, file) : 0;
    fclose(file);
    if (text == NULL || got != (size_t) size) {
        free(text);
        JS_ThrowReferenceError(ctx, "could not read module '%s'", name);
        return NULL;
    }
    text[size] = '\0';
    JSValue wrapped = call_cjs_wrap(ctx, name, text, (size_t) size);
    if (JS_IsException(wrapped)) {
        free(text);
        return NULL;
    }
    if (!JS_IsNull(wrapped)) {
        size_t wrapped_length = 0;
        const char *wrapped_text = JS_ToCStringLen(ctx, &wrapped_length, wrapped);
        JSModuleDef *cjs_module = wrapped_text != NULL ? compile_source(ctx, wrapped_text, wrapped_length, name) : NULL;
        if (wrapped_text != NULL) JS_FreeCString(ctx, wrapped_text);
        JS_FreeValue(ctx, wrapped);
        if (cjs_module != NULL) set_import_meta(ctx, cjs_module, name);
        free(text);
        return cjs_module;
    }
    JS_FreeValue(ctx, wrapped);
    size_t rewritten_length = 0;
    char *rewritten = rewrite_hot(text, (size_t) size, name, &rewritten_length);
    JSModuleDef *module = compile_source(ctx, rewritten ? rewritten : text, rewritten ? rewritten_length : (size_t) size, name);
    if (module != NULL) set_import_meta(ctx, module, name);
    free(rewritten);
    free(text);
    return module;
}

static JSValue js_sink(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    size_t length = 0;
    (void) this_val;
    if (argc < 1 || current_run == NULL) return JS_UNDEFINED;
    const char *text = JS_ToCStringLen(ctx, &length, argv[0]);
    if (text == NULL) return JS_EXCEPTION;
    current_run->host->sink(current_run->host->context, text, length);
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}

static JSValue js_call_host(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void) this_val;
    if (argc < 2 || current_run == NULL) return JS_ThrowTypeError(ctx, "callHost needs a verb name and its arguments");
    const char *name = JS_ToCString(ctx, argv[0]);
    if (name == NULL) return JS_EXCEPTION;
    const char *args = JS_ToCString(ctx, argv[1]);
    if (args == NULL) {
        JS_FreeCString(ctx, name);
        return JS_EXCEPTION;
    }
    char *reply = current_run->host->call(current_run->host->context, name, args, remaining_ms(current_run));
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, args);
    if (reply == NULL) return JS_ThrowInternalError(ctx, "the host returned no reply");
    JSValue out = JS_NewString(ctx, reply);
    free(reply);
    return out;
}

static JSValue install_bootstrap(JSContext *ctx, FxRun *run, const char *bootstrap, size_t bootstrap_length, const char *verbs_json, const char *root) {
    JSValue factory = JS_Eval(ctx, bootstrap, bootstrap_length, "<runcode>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(factory)) return factory;
    JSValue call_host = JS_NewCFunction(ctx, js_call_host, "callHost", 2);
    JSValue sink = JS_NewCFunction(ctx, js_sink, "sink", 1);
    JSValue verbs = JS_NewString(ctx, verbs_json);
    JSValue root_value = JS_NewString(ctx, root);
    JSValue args[4] = { call_host, verbs, sink, root_value };
    JSValue pair = JS_Call(ctx, factory, JS_UNDEFINED, 4, args);
    JS_FreeValue(ctx, factory);
    JS_FreeValue(ctx, call_host);
    JS_FreeValue(ctx, verbs);
    JS_FreeValue(ctx, sink);
    JS_FreeValue(ctx, root_value);
    if (JS_IsException(pair)) return pair;
    run->gm = JS_GetPropertyUint32(ctx, pair, 0);
    run->require = JS_GetPropertyUint32(ctx, pair, 1);
    JS_FreeValue(ctx, pair);
    return JS_UNDEFINED;
}

static char *deadline_message(unsigned long long budget_ms) {
    char buffer[160];
    snprintf(buffer, sizeof buffer, "the body passed its JavaScript deadline of %llu ms", budget_ms);
    return copy_text(buffer);
}

static JSValue js_exit_now(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t code = 0;
    (void) this_val;
    if (current_run == NULL) return JS_UNDEFINED;
    if (argc > 0 && JS_ToInt32(ctx, &code, argv[0]) < 0) return JS_EXCEPTION;
    current_run->exit_requested = 1;
    current_run->exit_code = (int) (code & 0xff);
    JSValue exc = JS_NewError(ctx);
    JS_SetUncatchableError(ctx, exc);
    return JS_Throw(ctx, exc);
}

static void drain_jobs(JSRuntime *rt, JSContext *ctx, char **error) {
    while (JS_IsJobPending(rt)) {
        JSContext *job_ctx = NULL;
        int result = JS_ExecutePendingJob(rt, &job_ctx);
        if (result < 0) {
            if (*error == NULL) *error = pending_error(job_ctx != NULL ? job_ctx : ctx);
            return;
        }
        if (result == 0) return;
    }
}

static void wait_for_promise(FxRun *run, JSRuntime *rt, JSContext *ctx, TJSRuntime *runtime, JSValueConst promise, char **error) {
    uv_loop_t *loop = gm_txiki_loop(runtime);
    for (;;) {
        drain_jobs(rt, ctx, error);
        if (*error != NULL || run->deadline_hit) return;
        if (JS_PromiseState(ctx, promise) == JS_PROMISE_REJECTED) return;
        if (!gm_txiki_loop_alive(runtime)) return;
        uv_run(loop, UV_RUN_ONCE);
    }
}

int fx_runcode_execute(const char *bootstrap, size_t bootstrap_length,
                       const char *verbs_json,
                       const char *root,
                       const char *source, size_t source_length,
                       const char *source_name, int is_module,
                       unsigned long long budget_ms,
                       const FxRunCodeHost *host,
                       char **out_value, char **out_error, int *out_exit_code) {
    FxRun run;
    FxRun *previous = current_run;
    char *error = NULL;
    char *value = NULL;
    int status = 1;
    JSValue promise = JS_UNDEFINED;
    JSValue result = JS_UNDEFINED;
    JSValue fn = JS_UNDEFINED;

    *out_value = NULL;
    *out_error = NULL;
    *out_exit_code = -1;
    memset(&run, 0, sizeof run);
    run.host = host;
    run.root = root;
    run.budget_ms = budget_ms;
    run.budget_ns = (uint64_t) budget_ms * 1000000ull;
    run.gm = JS_UNDEFINED;
    run.require = JS_UNDEFINED;

    TJSRuntime *runtime = gm_txiki_new();
    if (runtime == NULL) {
        *out_error = copy_text("the JavaScript runtime did not start");
        return 1;
    }
    JSContext *ctx = gm_txiki_context(runtime);
    JSRuntime *rt = JS_GetRuntime(ctx);
    uv_loop_t *loop = gm_txiki_loop(runtime);
    current_run = &run;
    run.started_ns = monotonic_ns();
    JS_SetModuleLoaderFunc(rt, normalize_module, load_module, NULL);
    JS_SetInterruptHandler(rt, interrupt_handler, &run);
    {
        JSValue global = JS_GetGlobalObject(ctx);
        JS_SetPropertyStr(ctx, global, "__fxExitNow", JS_NewCFunction(ctx, js_exit_now, "__fxExitNow", 1));
        JS_FreeValue(ctx, global);
    }
    uv_timer_init(loop, &run.timer);
    uv_unref((uv_handle_t *) &run.timer);
    run.timer.data = &run;

    JSValue boot = install_bootstrap(ctx, &run, bootstrap, bootstrap_length, verbs_json, root);
    if (JS_IsException(boot)) {
        error = pending_error(ctx);
    } else {
        JS_FreeValue(ctx, boot);
        drain_jobs(rt, ctx, &error);
        if (error == NULL && is_module) {
            JSValue compiled = JS_Eval(ctx, source, source_length, source_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
            if (JS_IsException(compiled)) {
                error = pending_error(ctx);
            } else if (JS_ResolveModule(ctx, compiled) < 0) {
                error = pending_error(ctx);
                JS_FreeValue(ctx, compiled);
            } else {
                JSModuleDef *definition = JS_VALUE_GET_PTR(compiled);
                set_import_meta(ctx, definition, source_name);
                JSValue evaluated = JS_EvalFunction(ctx, compiled);
                if (JS_IsException(evaluated)) {
                    error = pending_error(ctx);
                } else if (JS_PromiseState(ctx, evaluated) == JS_PROMISE_REJECTED) {
                    JSValue reason = JS_PromiseResult(ctx, evaluated);
                    error = value_text(ctx, reason);
                    JS_FreeValue(ctx, reason);
                    JS_FreeValue(ctx, evaluated);
                } else {
                    JS_FreeValue(ctx, evaluated);
                    JSValue ns = JS_GetModuleNamespace(ctx, definition);
                    fn = JS_GetPropertyStr(ctx, ns, "default");
                    JS_FreeValue(ctx, ns);
                    if (JS_IsException(fn)) {
                        error = pending_error(ctx);
                        fn = JS_UNDEFINED;
                    }
                }
            }
        } else if (error == NULL) {
            fn = JS_Eval(ctx, source, source_length, source_name, JS_EVAL_TYPE_GLOBAL);
            if (JS_IsException(fn)) {
                error = pending_error(ctx);
                fn = JS_UNDEFINED;
            }
        }
    }

    if (error == NULL && JS_IsUndefined(fn)) error = copy_text("the body does not load");
    if (error == NULL) {
        JSValue call_args[2] = { run.gm, run.require };
        promise = JS_Call(ctx, fn, JS_UNDEFINED, 2, call_args);
        if (JS_IsException(promise)) {
            error = pending_error(ctx);
            promise = JS_UNDEFINED;
        }
    }

    if (error == NULL) {
        uv_timer_start(&run.timer, deadline_fired, budget_ms, 0);
        wait_for_promise(&run, rt, ctx, runtime, promise, &error);
        uv_timer_stop(&run.timer);
        if (monotonic_ns() - run.started_ns >= run.budget_ns) run.deadline_hit = 1;
        if (!run.deadline_hit && error == NULL) {
            switch (JS_PromiseState(ctx, promise)) {
            case JS_PROMISE_FULFILLED: {
                result = JS_PromiseResult(ctx, promise);
                JSValue json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
                if (JS_IsException(json)) {
                    error = pending_error(ctx);
                } else if (JS_IsUndefined(json)) {
                    value = copy_text("null");
                } else {
                    const char *text = JS_ToCString(ctx, json);
                    value = copy_text(text != NULL ? text : "null");
                    if (text != NULL) JS_FreeCString(ctx, text);
                }
                JS_FreeValue(ctx, json);
                break;
            }
            case JS_PROMISE_REJECTED:
                result = JS_PromiseResult(ctx, promise);
                error = value_text(ctx, result);
                break;
            default:
                error = copy_text("the body stopped before it returned");
                break;
            }
        }
    }

    if (run.exit_requested) {
        char exit_text[48];
        free(error);
        free(value);
        value = NULL;
        *out_exit_code = run.exit_code;
        error = NULL;
        if (run.exit_code != 0) {
            snprintf(exit_text, sizeof exit_text, "process.exit(%d)", run.exit_code);
            error = copy_text(exit_text);
        }
    }
    if (run.deadline_hit) {
        free(error);
        free(value);
        value = NULL;
        error = deadline_message(budget_ms);
    }
    if (error == NULL) status = 0;

    uv_close((uv_handle_t *) &run.timer, NULL);
    uv_run(loop, UV_RUN_NOWAIT);
    JS_SetInterruptHandler(rt, NULL, NULL);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, promise);
    JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, run.gm);
    JS_FreeValue(ctx, run.require);
    gm_txiki_free(runtime);
    current_run = previous;

    *out_value = value;
    *out_error = error;
    return status;
}
