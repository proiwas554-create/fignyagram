#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#if TARGET_OS_SIMULATOR
// Xcode 27 simulator: TDLib's OpenSSL aborts while parsing the macOS system
// cert.pem. Redirect any attempt to open a system CA bundle to our compact
// RSA-only bundle (path supplied via FNY_CA_PATH). Interposing at libc level
// also covers statically linked OpenSSL inside TDLib.
static const char *fny_redirect(const char *path) {
    if (!path) return path;
    const char *replacement = getenv("FNY_CA_PATH");
    if (!replacement || !*replacement) return path;
    if (strstr(path, "cert.pem") || strstr(path, "ca-certificates.crt") ||
        strstr(path, "ca-bundle.crt") || strstr(path, "certs/ca")) {
        return replacement;
    }
    return path;
}

static FILE *(*orig_fopen)(const char *, const char *);
FILE *fopen(const char *path, const char *mode) {
    if (!orig_fopen) orig_fopen = dlsym(RTLD_NEXT, "fopen");
    return orig_fopen(fny_redirect(path), mode);
}

static int (*orig_open)(const char *, int, ...);
int open(const char *path, int flags, ...) {
    if (!orig_open) orig_open = dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
    return orig_open(fny_redirect(path), flags, mode);
}
#endif
