// Fallbacks for iOS 15/16 ObjC methods that apps built for a newer minimum call
// unguarded (the compiler drops @available checks at or below the deployment target).
// Each is added only if the class doesn't already respond, so on an iOS that has the
// real method this is a no-op. Candidates come from tools/scan_objc.py; this file is
// app-agnostic and grows with every ported app.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#include "waport.h"

static void add(const char *cls, BOOL meta, const char *name, const char *types, id block) {
    Class c = objc_getClass(cls);
    if (!c) return;
    if (meta) c = object_getClass(c);
    SEL s = sel_registerName(name);
    if (class_getInstanceMethod(c, s)) return;
    class_addMethod(c, s, imp_implementationWithBlock(block), types);
    shimlog(@"added %c[%s %s]", meta ? '+' : '-', cls, name);
}

// associated-object backed properties (getter returns the stored value or 0/nil)
static void objProp(const char *cls, const char *get, const char *set) {
    SEL key = sel_registerName(get);
    add(cls, NO, get, "@@:", ^id(id self) { return objc_getAssociatedObject(self, key); });
    if (set)
        add(cls, NO, set, "v@:@", ^(id self, id v) {
            objc_setAssociatedObject(self, key, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
}

static void intProp(const char *cls, const char *get, const char *set) {
    SEL key = sel_registerName(get);
    add(cls, NO, get, "q@:", ^NSInteger(id self) {
        return [objc_getAssociatedObject(self, key) integerValue];
    });
    if (set)
        add(cls, NO, set, "v@:q", ^(id self, NSInteger v) {
            objc_setAssociatedObject(self, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
}

static void boolProp(const char *cls, const char *get, const char *set) {
    SEL key = sel_registerName(get);
    add(cls, NO, get, "B@:", ^BOOL(id self) {
        return [objc_getAssociatedObject(self, key) boolValue];
    });
    if (set)
        add(cls, NO, set, "v@:B", ^(id self, BOOL v) {
            objc_setAssociatedObject(self, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
}

static void doubleProp(const char *cls, const char *get, const char *set) {
    SEL key = sel_registerName(get);
    add(cls, NO, get, "d@:", ^double(id self) {
        return [objc_getAssociatedObject(self, key) doubleValue];
    });
    if (set)
        add(cls, NO, set, "v@:d", ^(id self, double v) {
            objc_setAssociatedObject(self, key, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
}

static void nop(const char *cls, BOOL meta, const char *name, const char *types) {
    add(cls, meta, name, types, ^(id self) {});
}

// --- UIButtonConfiguration in nibs ------------------------------------------------
// Nibs compiled for iOS 15+ archive IB "Plain/Filled" buttons as UIButton +
// UIButtonConfiguration (title possibly only inside the configuration). On 14 that
// class doesn't exist: register a stub that decodes the parts we can use, and have
// -[UIButton initWithCoder:] apply them the legacy way.
static NSString *const kCfgKeys[] = {
    @"UIButtonConfigurationTitle", @"UIButtonConfigurationSubtitle",
    @"UIButtonConfigurationImage", @"UIButtonConfigurationBaseForegroundColor",
};

static void buttonConfigurationStub(void) {
    if (objc_getClass("UIButtonConfiguration")) return;
    Class c = objc_allocateClassPair([NSObject class], "UIButtonConfiguration", 0);
    static char kVals;
    class_addMethod(c, @selector(initWithCoder:), imp_implementationWithBlock(^id(id self, NSCoder *coder) {
        NSMutableDictionary *vals = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof kCfgKeys / sizeof *kCfgKeys; i++) {
            id v = [coder decodeObjectForKey:kCfgKeys[i]];
            if (v) vals[kCfgKeys[i]] = v;
        }
        objc_setAssociatedObject(self, &kVals, vals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return self;
    }), "@@:@");
    class_addMethod(c, @selector(encodeWithCoder:), imp_implementationWithBlock(^(id self, NSCoder *coder) {}), "v@:@");
    class_addMethod(c, @selector(copyWithZone:), imp_implementationWithBlock(^id(id self, void *z) { return self; }), "@@:^v");
    class_addMethod(c, sel_registerName("waport_values"), imp_implementationWithBlock(^id(id self) {
        return objc_getAssociatedObject(self, &kVals);
    }), "@@:");
    class_addMethod(object_getClass(c), @selector(supportsSecureCoding),
                    imp_implementationWithBlock(^BOOL(id cls) { return YES; }), "B@:");
    objc_registerClassPair(c);

    Method m = class_getInstanceMethod([UIButton class], @selector(initWithCoder:));
    id (*orig)(id, SEL, NSCoder *) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^id(UIButton *self, NSCoder *coder) {
        self = orig(self, @selector(initWithCoder:), coder);
        if (!self || ![coder containsValueForKey:@"UIButtonConfiguration"]) return self;
        id cfg = [coder decodeObjectForKey:@"UIButtonConfiguration"];
        NSDictionary *v = [cfg respondsToSelector:sel_registerName("waport_values")]
            ? MSG(id, id, SEL)(cfg, sel_registerName("waport_values")) : nil;
        id title = v[@"UIButtonConfigurationTitle"];
        id color = v[@"UIButtonConfigurationBaseForegroundColor"];
        id image = v[@"UIButtonConfigurationImage"];
        if ([title isKindOfClass:[NSAttributedString class]] && [title length])
            [self setAttributedTitle:title forState:UIControlStateNormal];
        else if ([title isKindOfClass:[NSString class]])
            [self setTitle:title forState:UIControlStateNormal];
        if (image)
            [self setImage:image forState:UIControlStateNormal];
        if (color) {
            self.tintColor = color;
            [self setTitleColor:color forState:UIControlStateNormal];
        }
        return self;
    }));
}

// --- UIView.keyboardLayoutGuide (iOS 15) -------------------------------------------
// A layout guide whose top follows the keyboard's top edge, or the safe-area bottom
// while no keyboard overlaps the view: bottom/leading/trailing pinned to the owning
// view, height = keyboard overlap (999) with top <= safe-area bottom (required).
@interface WaportKeyboardLayoutGuide : UILayoutGuide
@property (nonatomic) BOOL followsUndockedKeyboard;
@property (nonatomic, strong) NSLayoutConstraint *overlap;
@end

@implementation WaportKeyboardLayoutGuide
- (void)attachTo:(UIView *)v {
    [v addLayoutGuide:self];
    self.overlap = [self.heightAnchor constraintEqualToConstant:0];
    self.overlap.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [self.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [self.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [self.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
        [self.topAnchor constraintLessThanOrEqualToAnchor:v.safeAreaLayoutGuide.bottomAnchor],
        self.overlap,
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillHideNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardChanged:(NSNotification *)n {
    UIView *v = self.owningView;
    if (!v.window) return;
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat h = 0;
    if (![n.name isEqualToString:UIKeyboardWillHideNotification]) {
        kb = [v convertRect:[v.window convertRect:kb fromWindow:nil] fromView:nil];
        h = MAX(0, CGRectGetMaxY(v.bounds) - CGRectGetMinY(kb));
    }
    if (self.overlap.constant == h) return;
    double dur = [n.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSUInteger curve = [n.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
    self.overlap.constant = h;
    [UIView animateWithDuration:dur delay:0 options:(curve << 16) | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [v layoutIfNeeded]; } completion:nil];
}
@end

// --- the fallbacks ------------------------------------------------------------------

static void uikit(void) {
    static char kKLG;
    add("UIView", NO, "keyboardLayoutGuide", "@@:", ^id(UIView *self) {
        WaportKeyboardLayoutGuide *g = objc_getAssociatedObject(self, &kKLG);
        if (!g) {
            g = [WaportKeyboardLayoutGuide new];
            [g attachTo:self];
            objc_setAssociatedObject(self, &kKLG, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return g;
    });
    objProp("UIView", "maximumContentSizeCategory", "setMaximumContentSizeCategory:");
    objProp("UIView", "minimumContentSizeCategory", "setMinimumContentSizeCategory:");
    objProp("UIView", "focusEffect", "setFocusEffect:");
    objProp("UIView", "focusGroupIdentifier", "setFocusGroupIdentifier:");

    add("UIWindowScene", NO, "keyWindow", "@@:", ^id(UIWindowScene *self) {
        for (UIWindow *w in self.windows)
            if (w.isKeyWindow) return w;
        return self.windows.firstObject;
    });
    add("UIWindow", NO, "canBecomeKeyWindow", "B@:", ^BOOL(id self) { return YES; });

    add("UIViewController", NO, "sheetPresentationController", "@@:", ^id(id self) { return nil; });
    add("UIViewController", NO, "contentScrollViewForEdge:", "@@:Q", ^id(id self, NSUInteger e) { return nil; });
    add("UIViewController", NO, "setContentScrollView:forEdge:", "v@:@Q", ^(id self, id v, NSUInteger e) {});
    objProp("UIViewController", "focusGroupIdentifier", "setFocusGroupIdentifier:");

    // colors (light-mode values of the iOS 15 system colors)
    add("UIColor", YES, "tintColor", "@@:", ^id(id cls) { return [UIColor systemBlueColor]; });
    add("UIColor", YES, "systemCyanColor", "@@:", ^id(id cls) {
        return [UIColor colorWithRed:50 / 255. green:173 / 255. blue:230 / 255. alpha:1];
    });
    add("UIColor", YES, "systemMintColor", "@@:", ^id(id cls) {
        return [UIColor colorWithRed:0 green:199 / 255. blue:190 / 255. alpha:1];
    });

    // UIButton configuration API: no UIButtonConfiguration on 14, so configurations are
    // always nil; buttons keep whatever the legacy setters gave them.
    add("UIButton", YES, "buttonWithConfiguration:primaryAction:", "@@:@@", ^id(id cls, id cfg, UIAction *a) {
        return [cls buttonWithType:UIButtonTypeSystem primaryAction:a];
    });
    add("UIButton", NO, "configuration", "@@:", ^id(id self) { return nil; });
    add("UIButton", NO, "setConfiguration:", "v@:@", ^(id self, id c) {});
    objProp("UIButton", "configurationUpdateHandler", "setConfigurationUpdateHandler:");
    nop("UIButton", NO, "updateConfiguration", "v@:");
    nop("UIButton", NO, "setNeedsUpdateConfiguration", "v@:");
    add("UIButton", NO, "subtitleLabel", "@@:", ^id(id self) { return nil; });
    add("UIButton", NO, "isHovered", "B@:", ^BOOL(id self) { return NO; });
    boolProp("UIButton", "changesSelectionAsPrimaryAction", "setChangesSelectionAsPrimaryAction:");
    intProp("UIButton", "preferredBehavioralStyle", "setPreferredBehavioralStyle:");
    add("UIButton", NO, "behavioralStyle", "q@:", ^NSInteger(id self) { return 0; });
    intProp("UISlider", "preferredBehavioralStyle", "setPreferredBehavioralStyle:");
    add("UISlider", NO, "behavioralStyle", "q@:", ^NSInteger(id self) { return 0; });

    boolProp("UIBarButtonItem", "isHidden", "setHidden:");
    boolProp("UIBarButtonItem", "isSelected", "setSelected:");
    boolProp("UIBarButtonItem", "changesSelectionAsPrimaryAction", "setChangesSelectionAsPrimaryAction:");
    boolProp("UIBarButtonItemGroup", "isHidden", "setHidden:");

    // bars: iOS 15 on UIToolbar/UITabBar/UITabBarItem/compact UINavigationItem
    // (UINavigationBar has had it since 13). No scroll-edge state on 14: keep value only.
    objProp("UIToolbar", "scrollEdgeAppearance", "setScrollEdgeAppearance:");
    objProp("UIToolbar", "compactScrollEdgeAppearance", "setCompactScrollEdgeAppearance:");
    objProp("UITabBar", "scrollEdgeAppearance", "setScrollEdgeAppearance:");
    objProp("UITabBarItem", "scrollEdgeAppearance", "setScrollEdgeAppearance:");
    objProp("UINavigationItem", "compactScrollEdgeAppearance", "setCompactScrollEdgeAppearance:");
    intProp("UINavigationItem", "style", "setStyle:");

    // tables / collections
    doubleProp("UITableView", "sectionHeaderTopPadding", "setSectionHeaderTopPadding:");
    boolProp("UITableView", "isPrefetchingEnabled", "setPrefetchingEnabled:");
    boolProp("UITableView", "allowsFocus", "setAllowsFocus:");
    add("UITableView", NO, "reconfigureRowsAtIndexPaths:", "v@:@", ^(UITableView *self, NSArray *ips) {
        [UIView performWithoutAnimation:^{
            [self reloadRowsAtIndexPaths:ips withRowAnimation:UITableViewRowAnimationNone];
        }];
    });
    boolProp("UICollectionView", "allowsFocus", "setAllowsFocus:");
    add("UICollectionView", NO, "reconfigureItemsAtIndexPaths:", "v@:@", ^(UICollectionView *self, NSArray *ips) {
        [UIView performWithoutAnimation:^{ [self reloadItemsAtIndexPaths:ips]; }];
    });
    objProp("UITableViewCell", "configurationUpdateHandler", "setConfigurationUpdateHandler:");
    objProp("UICollectionViewCell", "configurationUpdateHandler", "setConfigurationUpdateHandler:");
    objProp("UITableViewHeaderFooterView", "configurationUpdateHandler", "setConfigurationUpdateHandler:");
    // 15: no compact scroll-edge state on 14, keep the value only (like UIToolbar above)
    objProp("UINavigationBar", "compactScrollEdgeAppearance", "setCompactScrollEdgeAppearance:");
    // 14.5
    intProp("UISplitViewController", "displayModeButtonVisibility", "setDisplayModeButtonVisibility:");
    add("NSDiffableDataSourceSnapshot", NO, "reconfigureItemsWithIdentifiers:", "v@:@", ^(id self, id ids) {
        MSG(void, id, SEL, id)(self, sel_registerName("reloadItemsWithIdentifiers:"), ids);
    });
    objProp("UIBackgroundConfiguration", "image", "setImage:");
    intProp("UIBackgroundConfiguration", "imageContentMode", "setImageContentMode:");
    boolProp("UIViewConfigurationState", "isPinned", "setPinned:");
    objProp("UIListSeparatorConfiguration", "visualEffect", "setVisualEffect:");

    // images
    add("UIImage", NO, "imageByPreparingThumbnailOfSize:", "@@:{CGSize=dd}", ^id(UIImage *self, CGSize sz) {
        UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
        f.scale = 1;
        return [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:f] imageWithActions:^(id ctx) {
            [self drawInRect:(CGRect){CGPointZero, sz}];
        }];
    });
    add("UIImage", NO, "prepareThumbnailOfSize:completionHandler:", "v@:{CGSize=dd}@?",
        ^(UIImage *self, CGSize sz, void (^done)(UIImage *)) {
            done(MSG(id, id, SEL, CGSize)(self, sel_registerName("imageByPreparingThumbnailOfSize:"), sz));
        });
    add("UIImage", NO, "imageByPreparingForDisplay", "@@:", ^id(UIImage *self) { return self; });
    add("UIImage", NO, "prepareForDisplayWithCompletionHandler:", "v@:@?", ^(UIImage *self, void (^done)(UIImage *)) {
        done(self);
    });
    add("UIImageSymbolConfiguration", YES, "configurationWithPaletteColors:", "@@:@", ^id(id cls, id colors) {
        return [UIImageSymbolConfiguration unspecifiedConfiguration];
    });
    add("UIImageSymbolConfiguration", YES, "configurationWithHierarchicalColor:", "@@:@", ^id(id cls, id color) {
        return [UIImageSymbolConfiguration unspecifiedConfiguration];
    });
    add("UIImageSymbolConfiguration", YES, "configurationPreferringMulticolor", "@@:", ^id(id cls) {
        return [UIImageSymbolConfiguration unspecifiedConfiguration];
    });

    // menus, keys, pointer, misc controls
    add("UIDeferredMenuElement", YES, "elementWithUncachedProvider:", "@@:@?", ^id(id cls, id provider) {
        return [cls elementWithProvider:provider];
    });
    objProp("UIMenuElement", "subtitle", "setSubtitle:");
    objProp("UIScene", "subtitle", "setSubtitle:");
    boolProp("UIKeyCommand", "wantsPriorityOverSystemBehavior", "setWantsPriorityOverSystemBehavior:");
    objProp("UIPointerStyle", "accessories", "setAccessories:");
    boolProp("UIDatePicker", "roundsToMinuteInterval", "setRoundsToMinuteInterval:");
    intProp("UIPageControl", "direction", "setDirection:");
    add("UISearchBar", NO, "isEnabled", "B@:", ^BOOL(UISearchBar *self) { return self.userInteractionEnabled; });
    add("UISearchBar", NO, "setEnabled:", "v@:B", ^(UISearchBar *self, BOOL e) { self.userInteractionEnabled = e; });

    // CADisplayLink / CAAnimation frame-rate ranges: {minimum, maximum, preferred}
    typedef struct { float minimum, maximum, preferred; } FrameRateRange;
    add("CADisplayLink", NO, "preferredFrameRateRange", "{CAFrameRateRange=fff}@:", ^FrameRateRange(CADisplayLink *self) {
        return (FrameRateRange){0, 0, self.preferredFramesPerSecond};
    });
    add("CADisplayLink", NO, "setPreferredFrameRateRange:", "v@:{CAFrameRateRange=fff}", ^(CADisplayLink *self, FrameRateRange r) {
        self.preferredFramesPerSecond = (NSInteger)r.preferred;
    });
    add("CAAnimation", NO, "preferredFrameRateRange", "{CAFrameRateRange=fff}@:", ^FrameRateRange(id self) {
        return (FrameRateRange){0, 0, 0};
    });
    add("CAAnimation", NO, "setPreferredFrameRateRange:", "v@:{CAFrameRateRange=fff}", ^(id self, FrameRateRange r) {});
}

static void foundation(void) {
    objProp("NSURLSessionTask", "delegate", "setDelegate:");
    intProp("NSURLRequest", "attribution", NULL);
    add("NSMutableURLRequest", NO, "setAttribution:", "v@:Q", ^(id self, NSUInteger a) {
        objc_setAssociatedObject(self, sel_registerName("attribution"), @(a), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    // 14.5: only the single NSUnderlyingErrorKey on 14
    add("NSError", NO, "underlyingErrors", "@@:", ^id(NSError *self) {
        id e = self.userInfo[NSUnderlyingErrorKey];
        return e ? @[e] : @[];
    });
    // 14.5: HTTP/3 hint, ignored
    boolProp("NSURLRequest", "assumesHTTP3Capable", NULL);
    boolProp("NSMutableURLRequest", "assumesHTTP3Capable", "setAssumesHTTP3Capable:");
    objProp("NSPersonNameComponentsFormatter", "locale", "setLocale:");
    add("NSUUID", NO, "compare:", "q@:@", ^NSComparisonResult(NSUUID *self, NSUUID *o) {
        return [self.UUIDString compare:o.UUIDString];
    });
    add("NSTextContainer", NO, "textLayoutManager", "@@:", ^id(id self) { return nil; });
    // attributes of the format's first character applied to the whole result
    add("NSAttributedString", NO, "initWithFormat:options:locale:arguments:", "@@:@Q@^v",
        ^id(NSAttributedString *self, NSAttributedString *fmt, NSUInteger opts, id locale, va_list args) {
            NSString *s = [[NSString alloc] initWithFormat:fmt.string locale:locale arguments:args];
            NSDictionary *attrs = fmt.length ? [fmt attributesAtIndex:0 effectiveRange:NULL] : nil;
            return [self initWithString:s attributes:attrs];
        });
}

static void notifications(void) {
    add("UNNotificationContent", NO, "contentByUpdatingWithProvider:error:", "@@:@^@",
        ^id(id self, id provider, NSError **err) {
            if (err) *err = nil;
            return [self copy];
        });
    intProp("UNNotificationContent", "interruptionLevel", NULL);
    add("UNMutableNotificationContent", NO, "setInterruptionLevel:", "v@:Q", ^(id self, NSUInteger v) {
        objc_setAssociatedObject(self, sel_registerName("interruptionLevel"), @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    doubleProp("UNNotificationContent", "relevanceScore", NULL);
    add("UNMutableNotificationContent", NO, "setRelevanceScore:", "v@:d", ^(id self, double v) {
        objc_setAssociatedObject(self, sel_registerName("relevanceScore"), @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    add("UNNotificationAction", YES, "actionWithIdentifier:title:options:icon:", "@@:@@Q@",
        ^id(id cls, id ident, id title, NSUInteger opts, id icon) {
            return MSG(id, id, SEL, id, id, NSUInteger)(cls, sel_registerName("actionWithIdentifier:title:options:"),
                                                        ident, title, opts);
        });
    add("UNTextInputNotificationAction", YES, "actionWithIdentifier:title:options:icon:textInputButtonTitle:textInputPlaceholder:",
        "@@:@@Q@@@", ^id(id cls, id ident, id title, NSUInteger opts, id icon, id button, id placeholder) {
            return MSG(id, id, SEL, id, id, NSUInteger, id, id)(cls,
                sel_registerName("actionWithIdentifier:title:options:textInputButtonTitle:textInputPlaceholder:"),
                ident, title, opts, button, placeholder);
        });
    add("UNNotificationAction", NO, "icon", "@@:", ^id(id self) { return nil; });

    // Intents
    add("INPerson", NO,
        "initWithPersonHandle:nameComponents:displayName:image:contactIdentifier:customIdentifier:isMe:suggestionType:",
        "@@:@@@@@@Bq",
        ^id(id self, id h, id nc, id dn, id img, id cid, id cuid, BOOL me, NSInteger st) {
            return MSG(id, id, SEL, id, id, id, id, id, id, BOOL)(self,
                sel_registerName("initWithPersonHandle:nameComponents:displayName:image:contactIdentifier:customIdentifier:isMe:"),
                h, nc, dn, img, cid, cuid, me);
        });
    objProp("INIntent", "donationMetadata", "setDonationMetadata:");
    boolProp("INFile", "removedOnCompletion", "setRemovedOnCompletion:");
    objProp("INRelevantShortcut", "widgetKind", "setWidgetKind:");
}

static void media(void) {
    add("AVCaptureDevice", YES, "activeMicrophoneMode", "q@:", ^NSInteger(id cls) { return 0; });
    add("AVCaptureDevice", YES, "preferredMicrophoneMode", "q@:", ^NSInteger(id cls) { return 0; });
    add("AVCaptureDevice", YES, "showSystemUserInterface:", "v@:q", ^(id cls, NSInteger s) {});
    add("AVCaptureDevice", NO, "isPortraitEffectActive", "B@:", ^BOOL(id self) { return NO; });
    add("AVCaptureDevice", NO, "minimumFocusDistance", "q@:", ^NSInteger(id self) { return -1; });
    add("AVCaptureDevice", NO, "activePrimaryConstituentDevice", "@@:", ^id(id self) { return nil; });
    add("AVCaptureDevice", NO, "activePrimaryConstituentDeviceSwitchingBehavior", "q@:", ^NSInteger(id self) { return 0; });
    add("AVCaptureDevice", NO, "activePrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions", "Q@:",
        ^NSUInteger(id self) { return 0; });
    add("AVCaptureDevice", NO, "primaryConstituentDeviceSwitchingBehavior", "q@:", ^NSInteger(id self) { return 0; });
    add("AVCaptureDevice", NO, "setPrimaryConstituentDeviceSwitchingBehavior:restrictedSwitchingBehaviorConditions:",
        "v@:qQ", ^(id self, NSInteger b, NSUInteger c) {});
    add("AVCaptureDeviceFormat", NO, "isHighPhotoQualitySupported", "B@:", ^BOOL(id self) { return NO; });
    // 14.5: Center Stage (off, unsupported), system-alert interruptions, rate-change hold
    add("AVCaptureDevice", YES, "centerStageControlMode", "q@:", ^NSInteger(id cls) { return 0; });
    add("AVCaptureDevice", YES, "setCenterStageControlMode:", "v@:q", ^(id cls, NSInteger m) {});
    add("AVCaptureDevice", YES, "isCenterStageEnabled", "B@:", ^BOOL(id cls) { return NO; });
    add("AVCaptureDevice", YES, "setCenterStageEnabled:", "v@:B", ^(id cls, BOOL e) {});
    add("AVCaptureDevice", NO, "isCenterStageActive", "B@:", ^BOOL(id self) { return NO; });
    add("AVCaptureDeviceFormat", NO, "isCenterStageSupported", "B@:", ^BOOL(id self) { return NO; });
    boolProp("AVAudioSession", "prefersNoInterruptionsFromSystemAlerts", NULL);
    add("AVAudioSession", NO, "setPrefersNoInterruptionsFromSystemAlerts:error:", "B@:B^@",
        ^BOOL(id self, BOOL v, NSError **err) { return YES; });
    boolProp("AVSampleBufferRenderSynchronizer", "delaysRateChangeUntilHasSufficientMediaData",
             "setDelaysRateChangeUntilHasSufficientMediaData:");
    // host time can't be passed on 14: start at media time `time` now
    add("AVSampleBufferRenderSynchronizer", NO, "setRate:time:atHostTime:", "v@:f{?=qiIq}{?=qiIq}",
        ^(AVSampleBufferRenderSynchronizer *self, float rate, CMTime time, CMTime host) {
            [self setRate:rate time:time];
        });
    // 15: content-source PiP (sample-buffer video, e.g. calls); without it there is no
    // controller to drive, so only keep the value
    objProp("AVPictureInPictureController", "contentSource", "setContentSource:");
    nop("AVPictureInPictureController", NO, "invalidatePlaybackState", "v@:");
    boolProp("AVSampleBufferDisplayLayer", "delaysRateChangeUntilHasSufficientMediaData",
             "setDelaysRateChangeUntilHasSufficientMediaData:");
    boolProp("AVSampleBufferAudioRenderer", "delaysRateChangeUntilHasSufficientMediaData",
             "setDelaysRateChangeUntilHasSufficientMediaData:");
    add("AVAudioSessionPortDescription", NO, "isSpatialAudioEnabled", "B@:", ^BOOL(id self) { return NO; });
    add("AVSampleBufferAudioRenderer", NO, "setAllowedAudioSpatializationFormats:", "v@:Q", ^(id self, NSUInteger f) {});
    add("AVPlayer", NO, "playbackCoordinator", "@@:", ^id(id self) { return nil; });

    // no-copy init -> copying init, then hand the caller's buffers back
    add("AVAudioPCMBuffer", NO, "initWithPCMFormat:bufferListNoCopy:deallocator:", "@@:@^v@?",
        ^id(AVAudioPCMBuffer *self, AVAudioFormat *fmt, const AudioBufferList *abl, void (^dealloc)(const AudioBufferList *)) {
            UInt32 bpf = fmt.streamDescription->mBytesPerFrame;
            AVAudioFrameCount frames = bpf ? abl->mBuffers[0].mDataByteSize / bpf : 0;
            self = [self initWithPCMFormat:fmt frameCapacity:frames];
            if (self) {
                AudioBufferList *dst = (AudioBufferList *)self.audioBufferList;
                for (UInt32 i = 0; i < abl->mNumberBuffers && i < dst->mNumberBuffers; i++)
                    memcpy(dst->mBuffers[i].mData, abl->mBuffers[i].mData,
                           MIN(abl->mBuffers[i].mDataByteSize, dst->mBuffers[i].mDataByteSize));
                self.frameLength = frames;
            }
            if (dealloc) dealloc(abl);
            return self;
        });

    // async loading (iOS 15) -> synchronous legacy accessors
    add("AVAsset", NO, "loadTracksWithMediaType:completionHandler:", "v@:@@?",
        ^(AVAsset *self, AVMediaType t, void (^done)(NSArray *, NSError *)) {
            done([self tracksWithMediaType:t], nil);
        });
    add("AVAsset", NO, "loadTracksWithMediaCharacteristic:completionHandler:", "v@:@@?",
        ^(AVAsset *self, AVMediaCharacteristic c, void (^done)(NSArray *, NSError *)) {
            done([self tracksWithMediaCharacteristic:c], nil);
        });
    add("AVAsset", NO, "loadTrackWithTrackID:completionHandler:", "v@:i@?",
        ^(AVAsset *self, CMPersistentTrackID tid, void (^done)(AVAssetTrack *, NSError *)) {
            done([self trackWithTrackID:tid], nil);
        });
    add("AVVideoCompositionInstruction", NO, "requiredSourceSampleDataTrackIDs", "@@:", ^id(id self) { return @[]; });
    add("AVMutableVideoCompositionInstruction", NO, "setRequiredSourceSampleDataTrackIDs:", "v@:@", ^(id self, id v) {});

    add("CHHapticPattern", NO, "initWithContentsOfURL:error:", "@@:@^@",
        ^id(id self, NSURL *url, NSError **err) {
            NSData *d = [NSData dataWithContentsOfURL:url options:0 error:err];
            id dict = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:err] : nil;
            if (!dict) return nil;
            return MSG(id, id, SEL, id, NSError **)(self, sel_registerName("initWithDictionary:error:"), dict, err);
        });

    add("VNFaceObservation", NO, "pitch", "@@:", ^id(id self) { return nil; });
    add("VNRecognizeTextRequest", NO, "supportedRecognitionLanguagesAndReturnError:", "@@:^@", ^id(id self, NSError **err) {
        NSInteger level = MSG(NSInteger, id, SEL)(self, sel_registerName("recognitionLevel"));
        NSUInteger rev = MSG(NSUInteger, id, SEL)(self, sel_registerName("revision"));
        return MSG(id, id, SEL, NSInteger, NSUInteger, NSError **)([self class],
            sel_registerName("supportedRecognitionLanguagesForTextRecognitionLevel:revision:error:"), level, rev, err);
    });
    intProp("MTLTextureDescriptor", "compressionType", "setCompressionType:");
}

static void web(void) {
    add("WKWebView", NO, "pauseAllMediaPlaybackWithCompletionHandler:", "v@:@?", ^(id self, void (^done)(void)) {
        if (done) done();
    });
    add("WKWebView", NO, "loadFileRequest:allowingReadAccessToURL:", "@@:@@", ^id(id self, NSURLRequest *r, NSURL *dir) {
        return MSG(id, id, SEL, id, id)(self, sel_registerName("loadFileURL:allowingReadAccessToURL:"), r.URL, dir);
    });
    add("WKWebView", NO, "loadSimulatedRequest:responseHTMLString:", "@@:@@", ^id(id self, NSURLRequest *r, NSString *html) {
        return MSG(id, id, SEL, id, id)(self, sel_registerName("loadHTMLString:baseURL:"), html, r.URL);
    });
    add("WKWebView", NO, "loadSimulatedRequest:response:responseData:", "@@:@@@",
        ^id(id self, NSURLRequest *r, NSURLResponse *resp, NSData *data) {
            return MSG(id, id, SEL, id, id, id, id)(self, sel_registerName("loadData:MIMEType:characterEncodingName:baseURL:"),
                                                    data, resp.MIMEType ?: @"text/html", resp.textEncodingName ?: @"utf-8", r.URL);
        });
    objProp("WKWebView", "underPageBackgroundColor", "setUnderPageBackgroundColor:");
    add("WKWebView", NO, "themeColor", "@@:", ^id(id self) { return nil; });
    objProp("SFSafariViewControllerConfiguration", "activityButton", "setActivityButton:");
}

static void other(void) {
    // StoreKit (iOS 16.1 ad attribution): report success, do nothing
    add("SKAdNetwork", YES, "updatePostbackConversionValue:coarseValue:lockWindow:completionHandler:", "v@:q@B@?",
        ^(id cls, NSInteger v, id coarse, BOOL lock, void (^done)(NSError *)) {
            if (done) done(nil);
        });
    objProp("PKPaymentRequestUpdate", "shippingMethods", "setShippingMethods:");
    add("PKTransitPassProperties", NO, "isBlocked", "B@:", ^BOOL(id self) { return NO; });
    const char *cpItems[] = {"CPListItem", "CPListImageRowItem", "CPMessageListItem"};
    for (size_t i = 0; i < sizeof cpItems / sizeof *cpItems; i++)
        boolProp(cpItems[i], "isEnabled", "setEnabled:");
    add("CPListSection", NO, "headerButton", "@@:", ^id(id self) { return nil; });
    add("CPListSection", NO, "headerImage", "@@:", ^id(id self) { return nil; });
}

__attribute__((constructor)) static void waport_compat(void) {
    waport_install_diagnostics();
    buttonConfigurationStub();
    uikit();
    foundation();
    notifications();
    media();
    web();
    other();
}
