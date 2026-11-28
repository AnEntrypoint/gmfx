#ifndef FX_RUNCODE_SHIM_H
#define FX_RUNCODE_SHIM_H

#include <stddef.h>

typedef struct FxRunCodeHost {
    void *context;
    char *(*call)(void *context, const char *name, const char *args, unsigned long long remaining_ms);
    void (*sink)(void *context, const char *text, size_t length);
    const char *(*embedded)(void *context, const char *name, size_t *length);
} FxRunCodeHost;

int fx_runcode_execute(const char *bootstrap, size_t bootstrap_length,
                       const char *verbs_json,
                       const char *root,
                       const char *source, size_t source_length,
                       const char *source_name, int is_module,
                       unsigned long long budget_ms,
                       const FxRunCodeHost *host,
                       char **out_value, char **out_error, int *out_exit_code);

#endif
