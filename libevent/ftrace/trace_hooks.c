#define _GNU_SOURCE
#include <execinfo.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int in_trace = 0;
static int depth = 0;

// 从 backtrace_symbols 字符串中提取函数名
static void extract_name(void *addr, char *out, int out_len) {
    void *buf[1] = {addr};
    char **sym = backtrace_symbols(buf, 1);
    out[0] = '\0';

    if (sym && sym[0]) {
        // 格式: ./program(func_name+0xoffset) [0xaddr]
        // 或: /path/lib.so(func_name+0xoffset) [0xaddr]
        char *p = strchr(sym[0], '(');
        if (p) {
            p++;
            char *end = strchr(p, '+');
            if (end) {
                int len = end - p;
                if (len > 0 && len < out_len - 1) {
                    strncpy(out, p, len);
                    out[len] = '\0';
                    free(sym);
                    return;
                }
            }
        }
        // 如果解析失败，保留原始字符串
        strncpy(out, sym[0], out_len - 1);
        out[out_len - 1] = '\0';
    }
    if (sym) free(sym);
}

void __attribute__((no_instrument_function))
__cyg_profile_func_enter(void *func, void *caller) {
    if (in_trace) return;
    in_trace = 1;

    char name[256];
    extract_name(func, name, sizeof(name));

    char buf[512];
    int n = snprintf(buf, sizeof(buf), " %*s-> %s\n", depth * 2, "", name);
    if (n > 0 && n < (int)sizeof(buf)) write(2, buf, n);

    depth++;
    in_trace = 0;
}

void __attribute__((no_instrument_function))
__cyg_profile_func_exit(void *func, void *caller) {
    if (in_trace) return;
    in_trace = 1;

    depth--;
    if (depth < 0) depth = 0;

    char name[256];
    extract_name(func, name, sizeof(name));

    char buf[512];
    int n = snprintf(buf, sizeof(buf), " %*s<- %s\n", depth * 2, "", name);
    if (n > 0 && n < (int)sizeof(buf)) write(2, buf, n);

    in_trace = 0;
}
