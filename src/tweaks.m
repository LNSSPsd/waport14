// Injected jailbreak tweaks (FLEX, ...) that enumerate every class. objc_copyClassList and
// objc_getClassList realize all classes, and realizing some of the app's Swift classes runs
// their metadata init, which calls an already-weak metadata accessor of a type newer than
// the target (e.g. ContinuousClock.Instant): null on 14. The app itself only uses
// those classes behind availability checks.
//
// So in every image that is neither in the shared cache nor in the app bundle, the two
// functions are rebound (symbol-pointer sections, fishhook style) to versions that list
// the classes of images outside the bundle only. App classes stay reachable by name.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <objc/runtime.h>
#include <string.h>

#include "waport.h"

#define MH_DYLIB_IN_CACHE 0x80000000

static char appDir[1024];
static size_t appDirLen;

static bool inApp(const char *path) {
    return path && appDirLen && !strncmp(path, appDir, appDirLen);
}

// Built once and cached (FLEX calls these in loops: rebuilding per call stalled the main
// thread past WhatsApp's launch deadline); rebuilt when more images are loaded.
static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
static Class __unsafe_unretained *cache;
static unsigned cacheCount;
static uint32_t cacheImages;

static void buildCache(void) {
    uint32_t ni = _dyld_image_count();
    if (cache && cacheImages == ni) return;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    size_t cap = 8192, n = 0;
    Class __unsafe_unretained *out = (Class __unsafe_unretained *)malloc((cap + 1) * sizeof *out);
    for (uint32_t i = 0; i < ni; i++) {
        const char *path = _dyld_get_image_name(i);
        if (inApp(path)) continue;
        unsigned c = 0;
        const char **names = objc_copyClassNamesForImage(path, &c);
        for (unsigned k = 0; k < c; k++) {
            Class cls = objc_getClass(names[k]);
            if (!cls) continue;
            if (n == cap) out = (Class __unsafe_unretained *)realloc(out, ((cap *= 2) + 1) * sizeof *out);
            out[n++] = cls;
        }
        free(names);
    }
    out[n] = Nil;
    free(cache);
    cache = out, cacheCount = (unsigned)n, cacheImages = ni;
    shimlog(@"tweak class list: %u classes from %u images in %.2fs", cacheCount, ni, CFAbsoluteTimeGetCurrent() - t0);
}

static Class *my_objc_copyClassList(unsigned *outCount) {
    os_unfair_lock_lock(&cacheLock);
    buildCache();
    Class __unsafe_unretained *out = (Class __unsafe_unretained *)malloc((cacheCount + 1) * sizeof *out);
    memcpy(out, cache, (cacheCount + 1) * sizeof *out);
    if (outCount) *outCount = cacheCount;
    os_unfair_lock_unlock(&cacheLock);
    return out;
}

static int my_objc_getClassList(Class *buf, int bufCount) {
    os_unfair_lock_lock(&cacheLock);
    buildCache();
    unsigned n = cacheCount;
    if (buf && bufCount > 0) memcpy(buf, cache, MIN((unsigned)bufCount, n) * sizeof *buf);
    os_unfair_lock_unlock(&cacheLock);
    return (int)n;
}

static const struct { const char *name; void *repl; } kRebind[] = {
    {"_objc_copyClassList", (void *)my_objc_copyClassList},
    {"_objc_getClassList", (void *)my_objc_getClassList},
};

static void rebindImage(const struct mach_header *mh, intptr_t slide) {
    if (mh->flags & MH_DYLIB_IN_CACHE || mh->magic != MH_MAGIC_64) return;
    Dl_info info;
    if (!dladdr(mh, &info) || inApp(info.dli_fname)) return;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *lc = (const void *)((const struct mach_header_64 *)mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
            linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const void *)lc;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);

    lc = (const void *)((const struct mach_header_64 *)mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)(slide + sect->addr);
            for (uint64_t j = 0; j < sect->size / sizeof(void *); j++) {
                uint32_t idx = indirect[sect->reserved1 + j];
                if (idx & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                const char *name = strs + syms[idx].n_un.n_strx;
                for (size_t r = 0; r < sizeof kRebind / sizeof *kRebind; r++) {
                    if (strcmp(name, kRebind[r].name)) continue;
                    vm_address_t page = (vm_address_t)&slots[j] & ~(vm_page_size - 1);
                    vm_protect(mach_task_self(), page, vm_page_size, false,
                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    slots[j] = kRebind[r].repl;
                    shimlog(@"tweak %s: %s rebound", info.dli_fname, kRebind[r].name + 1);
                }
            }
        }
    }
}

__attribute__((constructor)) static void installTweakGuards(void) {
    const char *exe = _dyld_get_image_name(0);
    const char *slash = exe ? strrchr(exe, '/') : NULL;
    if (!slash || (size_t)(slash - exe + 1) >= sizeof appDir) return;
    appDirLen = slash - exe + 1;
    memcpy(appDir, exe, appDirLen);
    appDir[appDirLen] = 0;
    _dyld_register_func_for_add_image(rebindImage);
}
