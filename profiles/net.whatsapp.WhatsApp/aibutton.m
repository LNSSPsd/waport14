// Meta AI floating action button on the chat list (WAAIFloatingActionButton): built on the
// iOS 15 Swift UIButton.Configuration (UIKit overlay type missing on 14, its configure
// crashes in the type lookup). Removed: configure is skipped and the button stays
// hidden and inert.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include "waport.h"

__attribute__((constructor)) static void removeAIButton(void) {
    Class c = objc_getClass("WAAIFloatingActionButton");
    if (!c) return;
    Method configure = class_getInstanceMethod(c, sel_registerName("configure"));
    if (configure)
        method_setImplementation(configure, imp_implementationWithBlock(^(UIView *self) {
            if (![self isKindOfClass:[UIView class]]) return;
            self.hidden = YES;
            self.userInteractionEnabled = NO;
            shimlog(@"Meta AI button removed");
        }));
    // the app may show it again later: only for this class, keep it hidden
    // superclass walk instead of +isSubclassOfClass: (no +initialize before main)
    bool isView = false;
    for (Class k = c; k && !isView; k = class_getSuperclass(k)) isView = k == objc_getClass("UIView");
    if (isView) {
        Method base = class_getInstanceMethod(objc_getClass("UIView"), @selector(setHidden:));
        void (*setHidden)(id, SEL, BOOL) = (void *)method_getImplementation(base);
        class_replaceMethod(c, @selector(setHidden:), imp_implementationWithBlock(^(id self, BOOL h) {
            setHidden(self, @selector(setHidden:), YES);
        }), method_getTypeEncoding(base));
    }
}
