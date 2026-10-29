/* SnowLuma hook 的 LD_PRELOAD 载入器（绕开 proot 下坏掉的 ptrace 注入）。
 * Termux + proot-distro(Ubuntu) 版：
 *   - SO 路径可用环境变量覆盖（SNOWLUMA_HOOK_SO / SNOWLUMA_RESIDENT_SO）
 *   - 多拦一个 epoll_pwait2（新版 Chromium/Node 会用它）
 * 行为：
 *   - 只作用于 QQ 主进程（带 --type= 的子进程直接跳过）
 *   - 在 QQ 主线程的 epoll 循环里执行 dlopen + start_dynamic
 *   - 把 stub 的 dlopen("/proc/self/fd/N") 换成从本地解包文件加载
 *     （proot 下 memfd 路径不可用，会 file too short）
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/epoll.h>

static const char *SO_PATH = "/opt/snowluma/native/snowluma-linux-arm64.so";
static const char *RESIDENT_SO = "/opt/qqstack/libsnowluma_linux_resident_dispatch.so";

static pid_t g_main_tid;
static volatile int g_started;
static struct timespec g_t0;

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ts.tv_sec - g_t0.tv_sec) * 1000L + (ts.tv_nsec - g_t0.tv_nsec) / 1000000L;
}

static int is_main_process(void) {
    char buf[4096];
    FILE *f = fopen("/proc/self/cmdline", "rb");
    if (!f) return 1;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    for (size_t i = 0; i < n; i++) if (buf[i] == 0) buf[i] = ' ';
    return strstr(buf, "--type=") == NULL;
}

/* ---- 拦截 memfd 版 resident dispatch 的 dlopen ---- */
void *dlopen(const char *filename, int flags) {
    static void *(*real_dlopen)(const char *, int) = NULL;
    if (!real_dlopen) real_dlopen = (void *(*)(const char *, int))dlsym(RTLD_NEXT, "dlopen");
    if (filename && (strncmp(filename, "/proc/self/fd/", 14) == 0 ||
                     strncmp(filename, "/proc/thread-self/fd/", 21) == 0 ||
                     strstr(filename, "memfd:") != NULL)) {
        const char *r = getenv("SNOWLUMA_RESIDENT_SO");
        if (!r || !*r) r = RESIDENT_SO;
        void *h = real_dlopen(r, RTLD_NOW | RTLD_GLOBAL);
        fprintf(stderr, "[slhook] resident dispatch <- %s (%s)\n", r, h ? "ok" : dlerror());
        if (h) return h;
    }
    if (getenv("SLHOOK_VERBOSE")) {
        void *h = real_dlopen(filename, flags);
        fprintf(stderr, "[slhook] dlopen(%s) -> %s\n", filename ? filename : "(null)",
                h ? "ok" : dlerror());
        return h;
    }
    return real_dlopen(filename, flags);
}

static void start_hook(void) {
    const char *so = getenv("SNOWLUMA_HOOK_SO");
    if (!so || !*so) so = SO_PATH;
    fprintf(stderr, "[slhook] pid=%d tid=%ld start on main thread\n",
            getpid(), (long)syscall(SYS_gettid));
    void *h = dlopen(so, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "[slhook] dlopen 失败: %s\n", dlerror()); return; }
    int (*is_loaded)(void) = (int (*)(void))dlsym(h, "snowluma_linux_hook_is_loaded");
    int (*start)(void) = (int (*)(void))dlsym(h, "snowluma_linux_hook_start_dynamic");
    const char *(*ver)(void) = (const char *(*)(void))dlsym(h, "snowluma_linux_hook_backend_version");
    const char *(*ctl)(void) = (const char *(*)(void))dlsym(h, "snowluma_linux_hook_control_socket");
    if (ver) fprintf(stderr, "[slhook] backend=%s\n", ver());
    if (is_loaded && is_loaded()) { fprintf(stderr, "[slhook] 已加载\n"); return; }
    if (!start) { fprintf(stderr, "[slhook] 缺 start_dynamic\n"); return; }
    int r = start();
    fprintf(stderr, "[slhook] start_dynamic -> %d loaded=%d ctl=%s\n", r,
            is_loaded ? is_loaded() : -1, ctl ? ctl() : "?");
}

static int self_maps_has(const char *needle) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    char line[1024]; int found = 0;
    while (fgets(line, sizeof(line), f)) { if (strstr(line, needle)) { found = 1; break; } }
    fclose(f);
    return found;
}

static void maybe_start(void) {
    if (g_started || !g_main_tid || syscall(SYS_gettid) != g_main_tid) return;
    const char *d = getenv("SLHOOK_DELAY_MS");
    long delay = d ? atol(d) : 5000;
    if (now_ms() < delay) return;
    const char *w = getenv("SLHOOK_WAIT_WRAPPER");
    int waitWrapper = !(w && *w == '0');
    static long waitFrom = 0;
    if (waitFrom == 0) waitFrom = now_ms();
    if (waitWrapper && now_ms() - waitFrom < 20000 && !self_maps_has("wrapper.node")) {
        static long last;
        if (now_ms() - last > 200) { last = now_ms(); fprintf(stderr, "[slhook] waiting wrapper.node\n"); }
        return;
    }
    g_started = 1;
    start_hook();
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    static int (*real)(int, struct epoll_event *, int, int) = NULL;
    if (!real) real = (int (*)(int, struct epoll_event *, int, int))dlsym(RTLD_NEXT, "epoll_wait");
    maybe_start();
    return real(epfd, events, maxevents, timeout);
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents, int timeout, const sigset_t *sigmask) {
    static int (*real)(int, struct epoll_event *, int, int, const sigset_t *) = NULL;
    if (!real) real = (int (*)(int, struct epoll_event *, int, int, const sigset_t *))dlsym(RTLD_NEXT, "epoll_pwait");
    maybe_start();
    return real(epfd, events, maxevents, timeout, sigmask);
}

int epoll_pwait2(int epfd, struct epoll_event *events, int maxevents,
                 const struct timespec *timeout, const sigset_t *sigmask) {
    static int (*real)(int, struct epoll_event *, int, const struct timespec *, const sigset_t *) = NULL;
    if (!real) real = (int (*)(int, struct epoll_event *, int, const struct timespec *, const sigset_t *))
        dlsym(RTLD_NEXT, "epoll_pwait2");
    maybe_start();
    if (!real) return -1;
    return real(epfd, events, maxevents, timeout, sigmask);
}

__attribute__((constructor)) static void slhook_init(void) {
    clock_gettime(CLOCK_MONOTONIC, &g_t0);
    if (!is_main_process()) return;
    g_main_tid = (pid_t)syscall(SYS_gettid);
    fprintf(stderr, "[slhook] armed in pid=%d main_tid=%d\n", getpid(), (int)g_main_tid);
}
