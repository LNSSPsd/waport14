// SwiftNativeNSObject (Swift 5.5 runtime, absent from 14's libswiftCore): NSObject
// subclass whose Swift subclasses (e.g. @objc actors) use Swift native refcounting.
// Port of swift/stdlib/public/runtime/SwiftNativeNSObject.mm. Built without ARC
// (build-shim.sh): it implements retain/release itself.

#import <Foundation/Foundation.h>
#include <stdint.h>

void *swift_allocObject(const void *metadata, size_t size, size_t alignMask);
void *swift_retain(void *);
void swift_release(void *);
size_t swift_retainCount(void *);
bool swift_isDeallocating(void *);
void *swift_tryRetain(void *);
void swift_rootObjCDealloc(void *);
id _objc_rootAutorelease(id);

__attribute__((visibility("default")))
@interface SwiftNativeNSObject : NSObject
@end

@implementation SwiftNativeNSObject

// Swift ClassMetadata: instance size (u32) at +48, alignment mask (u16) at +52.
// Only valid on Swift subclasses, as in the runtime.
+ (instancetype)allocWithZone:(NSZone *)zone {
    const uint8_t *cls = (const uint8_t *)self;
    return (id)swift_allocObject(cls, *(const uint32_t *)(cls + 48), *(const uint16_t *)(cls + 52));
}

+ (instancetype)alloc {
    return [self allocWithZone:NULL];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    return [super init];
}

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
    return NO;
}

- (id)retain {
    swift_retain(self);
    return self;
}

- (oneway void)release {
    swift_release(self);
}

- (id)autorelease {
    return _objc_rootAutorelease(self);
}

- (NSUInteger)retainCount {
    return swift_retainCount(self);
}

- (BOOL)_isDeallocating {
    return swift_isDeallocating(self);
}

- (BOOL)_tryRetain {
    return swift_tryRetain(self) != NULL;
}

- (BOOL)allowsWeakReference {
    return !swift_isDeallocating(self);
}

- (BOOL)retainWeakReference {
    return swift_tryRetain(self) != NULL;
}

- (void)dealloc {
    swift_rootObjCDealloc(self);
}

@end
