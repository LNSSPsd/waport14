// Logging, trap target and (WAPORT_LOG=1) diagnostics.
//
// <app container>/Documents/waport.log. Trap lines are always written: a trap is the
// last thing the process does, and iOS 14 crash reports don't say which symbol was
// missing. Everything else (method fallbacks installed, unrecognized selectors, uncaught
// exceptions, C++ terminate) only with WAPORT_LOG=1.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>

#include "waport.h"

static int logFD = -1;

static void openLog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        NSString *path = [docs stringByAppendingPathComponent:@"waport.log"];
        int flags = O_WRONLY | O_CREAT | O_APPEND;
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([a fileSize] > 1024 * 1024)
            flags |= O_TRUNC;
        logFD = open(path.fileSystemRepresentation, flags, 0644);
    });
}

static bool stderrToLog;

void waport_log(NSString *msg) {
    openLog();
    if (!stderrToLog) NSLog(@"waport: %@", msg);
    if (logFD < 0) return;
    NSString *line = [NSString stringWithFormat:@"%@ [%d %@] %@\n", [NSDate date], getpid(),
                      [[NSProcessInfo processInfo] processName], msg];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    write(logFD, d.bytes, d.length);
}

// Target of every generated trap (traps.S): an import the target iOS doesn't have and
// the shim doesn't implement. Async traps arrive here too (no context needed to abort).
__attribute__((visibility("default"), noreturn)) void waport_trap(const char *name) {
    waport_log([NSString stringWithFormat:@"TRAP missing function %s\n%@", name,
                [[NSThread callStackSymbols] componentsJoinedByString:@"\n"]]);
    abort();
}

#if WAPORT_LOG
static void logUnrecognized(id obj, SEL sel, BOOL meta) {
    waport_log([NSString stringWithFormat:@"UNRECOGNIZED %c[%s %s]\n%@", meta ? '+' : '-',
                object_getClassName(obj), sel_getName(sel),
                [[NSThread callStackSymbols] componentsJoinedByString:@"\n"]]);
}

static NSUncaughtExceptionHandler *prevHandler;
static void onUncaught(NSException *e) {
    waport_log([NSString stringWithFormat:@"UNCAUGHT %@: %@\n%@", e.name, e.reason,
                [e.callStackSymbols componentsJoinedByString:@"\n"]]);
    if (prevHandler) prevHandler(e);
}

void waport_install_cxx(void);   // compat_cxx.mm

// Every ObjC exception at throw time, caught or not (crash reporters in the app or in
// injected crash-reporter tweaks replace the uncaught handler, and _UIAppearance raises
// unrecognized-selector itself without doesNotRecognizeSelector:). First 40, the first
// 10 with a backtrace.
typedef id (*ExceptionPreprocessor)(id);
extern ExceptionPreprocessor objc_setExceptionPreprocessor(ExceptionPreprocessor fn);
static ExceptionPreprocessor prevPreprocessor;
static id onThrow(id exc) {
    static int count;
    int n = __sync_fetch_and_add(&count, 1);
    if (n < 40) {
        NSException *e = exc;
        NSString *bt = n < 10 ? [@"\n" stringByAppendingString:[[NSThread callStackSymbols] componentsJoinedByString:@"\n"]] : @"";
        waport_log([NSString stringWithFormat:@"THROW %@: %@%@", e.name, e.reason, bt]);
    }
    return prevPreprocessor ? prevPreprocessor(exc) : exc;
}

// Fatal signals: fault address, registers, frame-pointer backtrace as image+offset
// (iOS 14 crash reports of a patched app are often unsymbolicated or missing).
static void logFrame(char *buf, size_t cap, size_t *n, const char *tag, uintptr_t a) {
    Dl_info di;
    a &= 0x7FFFFFFFFFUL;   // strip pointer-authentication bits (arm64e)
    if (a && dladdr((void *)a, &di) && di.dli_fname) {
        const char *img = strrchr(di.dli_fname, '/');
        *n += snprintf(buf + *n, cap - *n, "%s %s+0x%lx %s\n", tag, img ? img + 1 : di.dli_fname,
                       (unsigned long)(a - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "");
    } else {
        *n += snprintf(buf + *n, cap - *n, "%s 0x%lx\n", tag, (unsigned long)a);
    }
}

// Handlers the app registers for these signals (e.g. its crash reporter) are wrapped:
// the app's sigaction/signal imports are bound to the shim (patch.py HOOKS), the app's
// handler is remembered and called after ours has logged.
static const int kSigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGABRT};
static struct sigaction appAct[NSIG];
static int (*realSigaction)(int, const struct sigaction *, struct sigaction *);

static bool watched(int sig) {
    for (size_t i = 0; i < sizeof kSigs / sizeof *kSigs; i++)
        if (kSigs[i] == sig) return true;
    return false;
}

static void onSignal(int sig, siginfo_t *si, void *ctx) {
    static char buf[16384];
    static volatile int logged;
    if (!logged++) {
        size_t n = 0;
        _STRUCT_MCONTEXT64 *mc = ((ucontext_t *)ctx)->uc_mcontext;
        uintptr_t pc = (uintptr_t)mc->__ss.__pc, lr = (uintptr_t)mc->__ss.__lr, fp = (uintptr_t)mc->__ss.__fp;
        n += snprintf(buf + n, sizeof buf - n, "SIGNAL %d at 0x%lx\n", sig, (unsigned long)si->si_addr);
        for (int i = 0; i < 29; i++)
            n += snprintf(buf + n, sizeof buf - n, "x%d=0x%llx%s", i, mc->__ss.__x[i], i % 4 == 3 ? "\n" : " ");
        n += snprintf(buf + n, sizeof buf - n, "\n");
        logFrame(buf, sizeof buf, &n, "pc", pc);
        logFrame(buf, sizeof buf, &n, "lr", lr);
        for (int i = 0; fp && !(fp & 7) && i < 64 && n < sizeof buf - 512; i++) {
            uintptr_t *f = (uintptr_t *)fp;
            logFrame(buf, sizeof buf, &n, "  ", f[1]);
            if (f[0] <= fp) break;
            fp = f[0];
        }
        waport_log([[NSString alloc] initWithBytes:buf length:MIN(n, sizeof buf) encoding:NSUTF8StringEncoding]);
    }
    struct sigaction *a = &appAct[sig];
    if (a->sa_flags & SA_SIGINFO && a->sa_sigaction) {
        a->sa_sigaction(sig, si, ctx);
    } else if (a->sa_handler != SIG_DFL && a->sa_handler != SIG_IGN && a->sa_handler) {
        a->sa_handler(sig);
    } else {
        struct sigaction dfl = {0};
        dfl.sa_handler = SIG_DFL;
        realSigaction(sig, &dfl, NULL);   // returning re-raises the fault -> default crash
    }
}

static void installSignalHandlers(void) {
    realSigaction = dlsym(RTLD_NEXT, "sigaction");
    // SA_ONSTACK: main-thread stack overflows can be logged too (alternate stacks are per thread)
    static char altstack[64 * 1024];
    stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = onSignal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (size_t i = 0; i < sizeof kSigs / sizeof *kSigs; i++)
        realSigaction(kSigs[i], &sa, &appAct[kSigs[i]]);
}

// bound to the app's sigaction / signal imports (patch.py HOOKS, diagnostic builds only)
__attribute__((visibility("default"))) int waport_sigaction(int sig, const struct sigaction *act,
                                                            struct sigaction *old) __asm__("_sigaction");
int waport_sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    if (!realSigaction || sig <= 0 || sig >= NSIG || !watched(sig))
        return (realSigaction ?: (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(RTLD_NEXT, "sigaction"))(sig, act, old);
    if (old) *old = appAct[sig];
    if (act) {
        appAct[sig] = *act;
        waport_log([NSString stringWithFormat:@"app handler for signal %d wrapped", sig]);
    }
    return 0;
}

// The app's crash reporter (Crashpad) takes the task's Mach exception ports: a crash then
// never becomes a signal and the process just ends, nothing logged. Bound to
// the app's imports (patch.py HOOKS, diagnostic builds only): log, report success, change
// nothing (swap returns the current ports).
__attribute__((visibility("default"))) kern_return_t waport_task_set_exception_ports(
    task_t task, exception_mask_t mask, mach_port_t port, exception_behavior_t behavior,
    thread_state_flavor_t flavor) __asm__("_task_set_exception_ports");
kern_return_t waport_task_set_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                              exception_behavior_t behavior, thread_state_flavor_t flavor) {
    waport_log([NSString stringWithFormat:@"task_set_exception_ports(mask 0x%x) ignored (diag: crashes go to signals)", mask]);
    return KERN_SUCCESS;
}

__attribute__((visibility("default"))) kern_return_t waport_task_swap_exception_ports(
    task_t task, exception_mask_t mask, mach_port_t port, exception_behavior_t behavior,
    thread_state_flavor_t flavor, exception_mask_array_t masks, mach_msg_type_number_t *count,
    exception_handler_array_t ports, exception_behavior_array_t behaviors,
    exception_flavor_array_t flavors) __asm__("_task_swap_exception_ports");
kern_return_t waport_task_swap_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                               exception_behavior_t behavior, thread_state_flavor_t flavor,
                                               exception_mask_array_t masks, mach_msg_type_number_t *count,
                                               exception_handler_array_t ports, exception_behavior_array_t behaviors,
                                               exception_flavor_array_t flavors) {
    waport_log([NSString stringWithFormat:@"task_swap_exception_ports(mask 0x%x) ignored (diag: crashes go to signals)", mask]);
    return task_get_exception_ports(task, mask, masks, count, ports, behaviors, flavors);
}

__attribute__((visibility("default"))) sig_t waport_signal(int sig, sig_t h) __asm__("_signal");
sig_t waport_signal(int sig, sig_t h) {
    struct sigaction a = {0}, old;
    a.sa_handler = h;
    if (waport_sigaction(sig, &a, &old) < 0) return SIG_ERR;
    return old.sa_flags & SA_SIGINFO ? (sig_t)old.sa_sigaction : old.sa_handler;
}

// Main-thread watchdog (black-screen diagnosis): a pinged main queue that hasn't answered
// for 5 s gets its backtrace logged. Frames are copied with the thread suspended and
// symbolized after resuming it (dladdr/malloc could need a lock the main thread holds).
static thread_t mainThread;
static volatile uint64_t mainPong;

static void logMainBacktrace(unsigned stalled) {
    uintptr_t frames[64];
    int nf = 0;
    if (thread_suspend(mainThread) != KERN_SUCCESS) return;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(mainThread, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
        frames[nf++] = (uintptr_t)arm_thread_state64_get_pc(st);
        frames[nf++] = (uintptr_t)arm_thread_state64_get_lr(st);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        vm_size_t got;
        uintptr_t f[2];
        while (fp && !(fp & 7) && nf < 64 &&
               vm_read_overwrite(mach_task_self(), fp, sizeof f, (vm_address_t)f, &got) == KERN_SUCCESS) {
            frames[nf++] = f[1];
            if (f[0] <= fp) break;
            fp = f[0];
        }
    }
    thread_resume(mainThread);
    static char buf[8192];
    size_t n = snprintf(buf, sizeof buf, "MAIN THREAD STALLED %us\n", stalled);
    for (int i = 0; i < nf && n < sizeof buf - 512; i++)
        logFrame(buf, sizeof buf, &n, i == 0 ? "pc" : i == 1 ? "lr" : "  ", frames[i]);
    waport_log([[NSString alloc] initWithBytes:buf length:MIN(n, sizeof buf) encoding:NSUTF8StringEncoding]);
}

// All threads (black screen with a responsive main thread: what is launch waiting on?)
static kern_return_t lastStateErr;
static int copyFrames(thread_t th, uintptr_t *frames, int max) {
    int nf = 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if ((lastStateErr = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt)) != KERN_SUCCESS) return 0;
    frames[nf++] = (uintptr_t)arm_thread_state64_get_pc(st);
    frames[nf++] = (uintptr_t)arm_thread_state64_get_lr(st);
    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st), f[2];
    vm_size_t got;
    while (fp && !(fp & 7) && nf < max &&
           vm_read_overwrite(mach_task_self(), fp, sizeof f, (vm_address_t)f, &got) == KERN_SUCCESS) {
        frames[nf++] = f[1];
        if (f[0] <= fp) break;
        fp = f[0];
    }
    return nf;
}

static void logAllThreads(unsigned t) {
    enum { MAXT = 160, MAXF = 24 };
    static uintptr_t frames[MAXT][MAXF];
    static int nframes[MAXT];
    static char names[MAXT][64];
    static kern_return_t errs[MAXT];
    thread_act_array_t threads;
    mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return;
    thread_t self = mach_thread_self();
    int count = 0;
    for (mach_msg_type_number_t i = 0; i < n && count < MAXT; i++) {
        if (threads[i] == self) continue;
        names[count][0] = 0;
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        if (pt) pthread_getname_np(pt, names[count], sizeof names[count]);
        if (thread_suspend(threads[i]) != KERN_SUCCESS) continue;
        nframes[count] = copyFrames(threads[i], frames[count], MAXF);
        errs[count] = nframes[count] ? 0 : lastStateErr;
        thread_resume(threads[i]);
        count++;
    }
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    mach_port_deallocate(mach_task_self(), self);
    waport_log([NSString stringWithFormat:@"THREADS at %us: %d", t, count]);
    static char buf[8192];
    for (int i = 0; i < count; i++) {
        size_t m = snprintf(buf, sizeof buf, "thread %d '%s' (%d frames, thread_get_state %d)\n", i, names[i],
                            nframes[i], errs[i]);
        for (int k = 0; k < nframes[i] && m < sizeof buf - 512; k++)
            logFrame(buf, sizeof buf, &m, k == 0 ? "pc" : k == 1 ? "lr" : "  ", frames[i][k]);
        waport_log([[NSString alloc] initWithBytes:buf length:MIN(m, sizeof buf) encoding:NSUTF8StringEncoding]);
    }
}

static double footprintMB(void) {
    task_vm_info_data_t vi = {0};
    mach_msg_type_number_t vc = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vc);
    return vi.phys_footprint / 1048576.;
}

static void startWatchdog(void) {
    mainThread = mach_thread_self();
    // lifecycle: a process that dies without a signal (SIGKILL by launch watchdog/jetsam, or
    // exit()) leaves only these, the heartbeat and the atexit line
    NSString *events[] = {@"UIApplicationDidBecomeActiveNotification", @"UIApplicationWillResignActiveNotification",
                          @"UIApplicationDidEnterBackgroundNotification", @"UIApplicationWillTerminateNotification",
                          @"UIApplicationDidReceiveMemoryWarningNotification", @"UISceneWillConnectNotification",
                          @"UISceneDidActivateNotification", @"UIWindowDidBecomeVisibleNotification",
                          @"UIWindowDidBecomeKeyNotification"};
    for (size_t i = 0; i < sizeof events / sizeof *events; i++)
        [[NSNotificationCenter defaultCenter] addObserverForName:events[i] object:nil queue:nil
                                                      usingBlock:^(NSNotification *n) {
            waport_log([NSString stringWithFormat:@"event %@ %@", n.name, n.object ? NSStringFromClass([n.object class]) : @""]);
        }];
    atexit_b(^{
        waport_log([NSString stringWithFormat:@"exit() called\n%@",
                    [[NSThread callStackSymbols] componentsJoinedByString:@"\n"]]);
    });
    // app extensions have small memory limits (jetsam kills without a signal): every second
    // at first, with the footprint jetsam counts
    BOOL appex = [[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"];
    if (appex)
        [NSThread detachNewThreadWithBlock:^{
            for (int i = 1; i <= 15; i++) {
                usleep(200000);
                waport_log([NSString stringWithFormat:@"footprint %.1f MB at %d ms", footprintMB(), i * 200]);
            }
        }];
    [NSThread detachNewThreadWithBlock:^{
        uint64_t sent = 0;
        unsigned stalled = 0;
        for (unsigned t = 1;; t++) {
            sleep(1);
            if (t == 10 || t == 17) logAllThreads(t);
            if ((appex && t < 5) || (t <= 120 ? t % 5 == 0 : t % 60 == 0)) {
                struct task_basic_info_64 ti;
                mach_msg_type_number_t c = TASK_BASIC_INFO_64_COUNT;
                task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&ti, &c);
                waport_log([NSString stringWithFormat:@"alive %us, resident %llu MB, footprint %.1f MB%@", t,
                            (unsigned long long)ti.resident_size >> 20, footprintMB(),
                            stalled ? @", main stalled" : @""]);
            }
            if (mainPong == sent) {
                if (stalled) waport_log([NSString stringWithFormat:@"main thread answered after %us", stalled]);
                stalled = 0;
                uint64_t s = ++sent;
                dispatch_async(dispatch_get_main_queue(), ^{ mainPong = s; });
            } else if (++stalled == 5 || stalled == 15 || stalled % 60 == 0) {
                logMainBacktrace(stalled);
            }
        }
    }];
}

// Dirty memory by owner (image segments, else VM tag): what makes up the footprint
static void logMemoryMap(NSString *label) {
    struct range { uintptr_t lo, hi; const char *name; };
    uint32_t n = _dyld_image_count();
    struct range *r = calloc(n * 8, sizeof *r);
    size_t nr = 0;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const char *path = _dyld_get_image_name(i), *base = strrchr(path, '/');
        const struct load_command *lc = (const void *)(h + 1);
        for (uint32_t c = 0; c < h->ncmds && nr < n * 8; c++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
            if (lc->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *sg = (const void *)lc;
            if (!sg->vmsize || !strcmp(sg->segname, "__PAGEZERO")) continue;
            r[nr++] = (struct range){sg->vmaddr + slide, sg->vmaddr + slide + sg->vmsize, base ? base + 1 : path};
        }
    }
    NSMutableDictionary<NSString *, NSNumber *> *kb = [NSMutableDictionary dictionary];
    vm_address_t addr = 0;
    natural_t depth = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt))
            break;
        if (info.is_submap) { depth++; continue; }
        if (info.share_mode != SM_SHARED && info.share_mode != SM_TRUESHARED && info.share_mode != SM_EMPTY) {
            uint64_t dirty = (uint64_t)(info.pages_dirtied + info.pages_swapped_out) * vm_page_size;
            if (dirty) {
                NSString *owner = nil;
                for (size_t i = 0; i < nr && !owner; i++)
                    if (addr < r[i].hi && addr + size > r[i].lo) owner = @(r[i].name);
                if (!owner) owner = [NSString stringWithFormat:@"tag %u", info.user_tag];
                kb[owner] = @(kb[owner].unsignedLongLongValue + (dirty >> 10));
            }
        }
        addr += size;
    }
    free(r);
    NSArray *keys = [kb keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NSMutableString *out = [NSMutableString stringWithFormat:@"memory %@: footprint %.1f MB, dirty KB by owner (tags: 1 malloc, 2 small, 3 large, 7 tiny, 11 nano, 30 stack):",
                                                           label, footprintMB()];
    for (NSUInteger i = 0; i < keys.count && i < 25; i++) [out appendFormat:@"\n  %6llu %@", kb[keys[i]].unsignedLongLongValue, keys[i]];
    waport_log(out);
}

// Notification service extension lifecycle: the request, the content handler call, the
// time-limit callback (an extension that dies silently shows how far it got)
static void traceNotificationService(void) {
    NSDictionary *ext = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSExtension"];
    if (![ext[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.usernotifications.service"]) return;
    Class c = NSClassFromString(ext[@"NSExtensionPrincipalClass"]);
    SEL rs = sel_registerName("didReceiveNotificationRequest:withContentHandler:");
    Method m = c ? class_getInstanceMethod(c, rs) : NULL;
    if (!m) {
        waport_log([NSString stringWithFormat:@"notification service %@: no %s", ext[@"NSExtensionPrincipalClass"], sel_getName(rs)]);
        return;
    }
    void (*orig)(id, SEL, id, id) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, id request, void (^handler)(id)) {
        id content = [request valueForKey:@"content"];
        NSDictionary *info = [content valueForKey:@"userInfo"];
        waport_log([NSString stringWithFormat:@"notification service: request %@, payload keys %@, footprint %.1f MB, limit %d MB",
                    [request valueForKey:@"identifier"], [[info allKeys] componentsJoinedByString:@","], footprintMB(),
                    waport_memlimit()]);
        logMemoryMap(@"at request");
        void (^h)(id) = handler;
        orig(self, rs, request, ^(id result) {
            waport_log([NSString stringWithFormat:@"notification service: content handler, title %lu chars, body %lu chars",
                        (unsigned long)[[result valueForKey:@"title"] length], (unsigned long)[[result valueForKey:@"body"] length]]);
            h(result);
        });
    }));
    SEL es = sel_registerName("serviceExtensionTimeWillExpire");
    Method em = class_getInstanceMethod(c, es);
    if (em) {
        void (*eorig)(id, SEL) = (void *)method_getImplementation(em);
        method_setImplementation(em, imp_implementationWithBlock(^(id self) {
            waport_log(@"notification service: time will expire");
            eorig(self, es);
        }));
    }
}

void waport_install_diagnostics(void) {
    // stderr -> waport.log: Swift fatal errors (e.g. continuation misuse), runtime warnings,
    // anything printed. Direct writes, so they land even if the process dies right after.
    openLog();
    if (logFD >= 0 && dup2(logFD, STDERR_FILENO) >= 0) stderrToLog = true;
    installSignalHandlers();
    prevPreprocessor = objc_setExceptionPreprocessor(onThrow);
    startWatchdog();
    waport_log([NSString stringWithFormat:@"=== launch %@ (%@) waport build " WAPORT_BUILD ", footprint %.1f MB",
                [[NSBundle mainBundle] bundleIdentifier], [[NSProcessInfo processInfo] operatingSystemVersionString], footprintMB()]);
    waport_install_cxx();
    for (int meta = 0; meta < 2; meta++) {
        Class c = meta ? object_getClass([NSObject class]) : [NSObject class];
        Method m = class_getInstanceMethod(c, @selector(doesNotRecognizeSelector:));
        void (*orig)(id, SEL, SEL) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, SEL sel) {
            logUnrecognized(self, sel, meta);
            orig(self, @selector(doesNotRecognizeSelector:), sel);
        }));
    }
    prevHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(onUncaught);
    traceNotificationService();
}
#else
void waport_install_diagnostics(void) {}
#endif
