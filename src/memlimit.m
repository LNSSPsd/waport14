// App extensions run under small jetsam limits (a notification service extension: 24 MB),
// and jetsam kills without a signal. iOS 14's dyld binds every data page of an image at
// load, so an extension that links a large framework of an app built for a newer iOS starts
// close to its limit and dies on its first real work. patch.py signs app extensions with
// com.apple.private.memorystatus (honored under TrollStore), which lets a process change its
// own limit: raised here, never lowered.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

#include "waport.h"

#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES 7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL 0x1
#define EXTENSION_LIMIT_MB 64

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memlimit_properties;

typedef int (*memorystatus_control_fn)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);

static memorystatus_control_fn control(void) {
    return (memorystatus_control_fn)dlsym(RTLD_DEFAULT, "memorystatus_control");
}

// active limit in MB (-1: none or unknown)
int waport_memlimit(void) {
    memlimit_properties p = {0};
    memorystatus_control_fn f = control();
    if (!f || f(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, getpid(), 0, &p, sizeof p)) return -1;
    return p.memlimit_active;
}

__attribute__((constructor)) static void raiseExtensionLimit(void) {
    if (![[[NSBundle mainBundle] bundlePath] hasSuffix:@".appex"]) return;
    memorystatus_control_fn f = control();
    memlimit_properties p = {0};
    if (!f || f(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, getpid(), 0, &p, sizeof p)) {
        shimlog(@"memory limit: can't read (%s)", strerror(errno));
        return;
    }
    memlimit_properties q = p;
    if (q.memlimit_active > 0 && q.memlimit_active < EXTENSION_LIMIT_MB) q.memlimit_active = EXTENSION_LIMIT_MB;
    if (q.memlimit_inactive > 0 && q.memlimit_inactive < EXTENSION_LIMIT_MB) q.memlimit_inactive = EXTENSION_LIMIT_MB;
    q.memlimit_active_attr |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    q.memlimit_inactive_attr |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    if (q.memlimit_active == p.memlimit_active && q.memlimit_inactive == p.memlimit_inactive) return;
    int r = f(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, getpid(), 0, &q, sizeof q);
    shimlog(@"memory limit: %d/%d MB -> %d/%d MB%s%s", p.memlimit_active, p.memlimit_inactive, q.memlimit_active,
            q.memlimit_inactive, r ? ": failed, " : "", r ? strerror(errno) : "");
}
