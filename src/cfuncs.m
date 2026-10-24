// iOS 15+ C functions with an iOS 14 equivalent. Bound to the shim by patch.py when the
// target's own library doesn't export them.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <objc/message.h>

#define EXPORT __attribute__((visibility("default")))

EXPORT CFTypeRef CVBufferCopyAttachment(CVBufferRef buf, CFStringRef key, CVAttachmentMode *mode) {
    CFTypeRef v = CVBufferGetAttachment(buf, key, mode);
    return v ? CFRetain(v) : NULL;
}

EXPORT CFDictionaryRef CVBufferCopyAttachments(CVBufferRef buf, CVAttachmentMode mode) {
    CFDictionaryRef d = CVBufferGetAttachments(buf, mode);
    return d ? CFDictionaryCreateCopy(NULL, d) : NULL;
}

EXPORT Boolean CVBufferHasAttachment(CVBufferRef buf, CFStringRef key) {
    return CVBufferGetAttachment(buf, key, NULL) != NULL;
}

// 14 has no HDR colour-space queries: decide by the colour space's name
static bool nameHas(CGColorSpaceRef cs, CFStringRef what) {
    CFStringRef n = cs ? CGColorSpaceGetName(cs) : NULL;
    return n && CFStringFind(n, what, 0).location != kCFNotFound;
}
EXPORT bool CGColorSpaceIsHLGBased(CGColorSpaceRef cs) { return nameHas(cs, CFSTR("HLG")); }
EXPORT bool CGColorSpaceIsPQBased(CGColorSpaceRef cs) { return nameHas(cs, CFSTR("PQ")); }

typedef struct { float minimum, maximum, preferred; } CAFrameRateRange;
EXPORT CAFrameRateRange CAFrameRateRangeMake(float minimum, float maximum, float preferred) {
    return (CAFrameRateRange){minimum, maximum, preferred};
}

// renamed in 15 (MasterClock -> SourceClock), same signature
EXPORT OSStatus CMTimebaseCreateWithSourceClock(CFAllocatorRef a, CMClockRef clock, CMTimebaseRef *out) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CMTimebaseCreateWithMasterClock(a, clock, out);
#pragma clang diagnostic pop
}

EXPORT CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
    CFIndex n = SecTrustGetCertificateCount(trust);
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, n, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < n; i++)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CFArrayAppendValue(a, SecTrustGetCertificateAtIndex(trust, i));
#pragma clang diagnostic pop
    return a;
}

// async backtraces (15): report none
EXPORT size_t backtrace_async(void **array, size_t size, uint32_t *task_id) {
    if (task_id) *task_id = 0;
    return 0;
}

// Swift 5.5 runtime entry point. On 13/14 the back-deployed libswift_Concurrency has
// the same function as ...Standalone (what Swift's own back-deployment shim calls).
EXPORT const void *swift_getFunctionTypeMetadataGlobalActor(uintptr_t flags, uintptr_t diffKind,
                                                            const void *const *params, const uint32_t *pflags,
                                                            const void *result, const void *actor) {
    static const void *(*real)(uintptr_t, uintptr_t, const void *const *, const uint32_t *, const void *, const void *);
    if (!real)
        real = dlsym(RTLD_DEFAULT, "swift_getFunctionTypeMetadataGlobalActorStandalone");
    return real(flags, diffKind, params, pflags, result, actor);
}

// CoreData overlay (15): NSManagedObjectContext.performAndWait<T>(_: () throws -> T)
// rethrows -> T, via the Swift-ABI entry in shim.S. waport_swift_call runs the closure
// (result to out, error returned) inside -performBlockAndWait: (its ObjC name).
void *waport_swift_call(void *fn, void *ctx, void *out);
void *waport_moc_performAndWait(id moc, void *fn, void *ctx, void *out) {
    __block void *err = NULL;
    ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(moc, sel_registerName("performBlockAndWait:"), ^{
        err = waport_swift_call(fn, ctx, out);
    });
    return err;
}
