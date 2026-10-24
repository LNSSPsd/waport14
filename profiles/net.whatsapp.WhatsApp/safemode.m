// WhatsApp safe mode (diagnostic builds): every launch crash is counted
// (-[WhatsAppAppDelegate checkForInstaCrashLoop]: prefs appInstaCrashDates /
// appInstaCrashLoopCount), and past a threshold the app starts in a safe mode instead of
// normally (WASafeModeViewController, or a recovery path that shows nothing: black screen
// until the launch watchdog kills it). While porting, every run crashes, so the counters
// are reset before -setupSafeMode:launchOptions: reads them and each run takes the normal
// path. The values found and the safe mode chosen are logged.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

#include "waport.h"

#if WAPORT_LOG
static id prefsInstance(void) {
    id (*get)(void) = dlsym(RTLD_DEFAULT, "WACurrentProcessAppPreferencesGetSharedInstance");
    return get ? get() : nil;
}

static void resetCrashLoop(void) {
    id p = prefsInstance();
    if (!p) { shimlog(@"safe mode: no current-process preferences"); return; }
    SEL getters[] = {sel_registerName("appInstaCrashDates"), sel_registerName("appInstaCrashLoopCount"),
                     sel_registerName("appSafeModeAppVersion"), sel_registerName("appConsecutiveEmailSupportFlowCount")};
    for (size_t i = 0; i < sizeof getters / sizeof *getters; i++) {
        Method m = class_getInstanceMethod(object_getClass(p), getters[i]);
        if (!m) { shimlog(@"safe mode: %@ lacks %s", [p class], sel_getName(getters[i])); continue; }
        char rt[16];
        method_getReturnType(m, rt, sizeof rt);
        if (rt[0] == '@') shimlog(@"safe mode: %s = %@", sel_getName(getters[i]), MSG(id, id, SEL)(p, getters[i]));
        else shimlog(@"safe mode: %s = %ld", sel_getName(getters[i]), (long)MSG(NSInteger, id, SEL)(p, getters[i]));
    }
    SEL dates = sel_registerName("setAppInstaCrashDates:"), loop = sel_registerName("setAppInstaCrashLoopCount:"),
        ver = sel_registerName("setAppSafeModeAppVersion:"), email = sel_registerName("setAppConsecutiveEmailSupportFlowCount:");
    if ([p respondsToSelector:dates]) MSG(void, id, SEL, id)(p, dates, @[]);
    if ([p respondsToSelector:loop]) MSG(void, id, SEL, NSInteger)(p, loop, 0);
    if ([p respondsToSelector:ver]) MSG(void, id, SEL, id)(p, ver, nil);
    if ([p respondsToSelector:email]) MSG(void, id, SEL, NSInteger)(p, email, 0);
    shimlog(@"safe mode: crash-loop counters reset (%@)", [p class]);
}

__attribute__((constructor)) static void hookSafeMode(void) {
    Class c = objc_getClass("WhatsAppAppDelegate");
    SEL sel = sel_registerName("setupSafeMode:launchOptions:");
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) { shimlog(@"safe mode: -[WhatsAppAppDelegate setupSafeMode:launchOptions:] not found"); return; }
    BOOL (*orig)(id, SEL, id, id) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self, id app, id opts) {
        resetCrashLoop();
        BOOL r = orig(self, sel, app, opts);
        SEL mode = sel_registerName("safeMode");
        shimlog(@"safe mode: setupSafeMode -> %d, safeMode = %ld", r,
                [self respondsToSelector:mode] ? (long)MSG(NSInteger, id, SEL)(self, mode) : -1L);
        return r;
    }));
}
#endif
