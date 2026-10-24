// Registration phone-number field (WAPhoneNumberTextField): typing had no effect. Its
// UIFieldEditor had no text storage, so every edit read back nil. UIKit 14
// creates the field's layout manager lazily (-[UITextField _layoutManager]) and attaches it
// to _textStorage there. WAPhoneNumberTextField's setFrame: override calls reformatTextField
// (setFont: -> _layoutManager), and on 14 UITextField's initWithFrame: sets the frame before
// _initTextStorage: the layout manager is created against a nil storage and never attached
// (traced: _initTextStorage, but no addLayoutManager:, for this field only). So
// reformatTextField does nothing until the storage exists; commonInit reformats again.
// Diag builds also trace the edit path.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>

#include "waport.h"

__attribute__((constructor)) static void phoneFieldInitOrder(void) {
    Class field = objc_getClass("WAPhoneNumberTextField");
    Ivar storage = class_getInstanceVariable(objc_getClass("UITextField"), "_textStorage");
    Method m = field ? class_getInstanceMethod(field, sel_registerName("reformatTextField")) : NULL;
    if (!storage || !m) return;
    void (*reformat)(id, SEL) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        if (!object_getIvar(self, storage)) {
            shimlog(@"phonefield: reformatTextField before _initTextStorage skipped");
            return;
        }
        reformat(self, sel_registerName("reformatTextField"));
    }));
}

#if WAPORT_LOG
static NSString *textOf(id v) {
    return [v respondsToSelector:@selector(text)] ? [NSString stringWithFormat:@"'%@'", [v text]] : @"-";
}

// UITextField's own view of its content: raw -text, attributedText and
// the private field editor (UIFieldEditor, holds the text while editing on 14).
static NSString *uikitState(UITextField *tf) {
    NSString *(*raw)(id, SEL) = (void *)method_getImplementation(
        class_getInstanceMethod(objc_getClass("UITextField"), @selector(text)));
    NSMutableString *s = [NSMutableString stringWithFormat:@"raw %@, attributed '%@', editing %d",
                          raw(tf, @selector(text)) ?: @"nil", tf.attributedText.string, tf.isEditing];
    @try {
        id fe = [tf valueForKey:@"_fieldEditor"];
        [s appendFormat:@", editor %s", fe ? object_getClassName(fe) : "nil"];
        if ([fe respondsToSelector:@selector(text)]) [s appendFormat:@" text '%@'", [fe text]];
        if ([fe respondsToSelector:@selector(textStorage)])
            [s appendFormat:@" storage '%@'", [[fe textStorage] string]];
    } @catch (id e) {
        [s appendFormat:@", editor: %@", e];
    }
    return s;
}

// Object ivars of obj declared by class k (name = class of value, or nil).
static NSString *ivars(id obj, Class k) {
    NSMutableString *s = [NSMutableString string];
    unsigned n = 0;
    Ivar *iv = class_copyIvarList(k, &n);
    for (unsigned i = 0; i < n; i++) {
        const char *t = ivar_getTypeEncoding(iv[i]);
        if (!t || t[0] != '@') continue;
        id v = object_getIvar(obj, iv[i]);
        [s appendFormat:@" %s=%s", ivar_getName(iv[i]), v ? object_getClassName(v) : "nil"];
    }
    free(iv);
    return s;
}

static void dumpOnce(UITextField *tf) {
    static bool done;
    if (done || !tf.isEditing) return;
    done = true;
    UITextField *plain = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
    plain.text = @"7";
    shimlog(@"phonefield: plain UITextField after setText:'7': [%@]", uikitState(plain));
    shimlog(@"phonefield: UITextField ivars:%@", ivars(tf, objc_getClass("UITextField")));
    // replay the phone field's configuration on a fresh field: which step drops the
    // field editor's text storage?
    NSString *(^storage)(UITextField *) = ^NSString *(UITextField *f) {
        @try {
            id st = [[f valueForKey:@"_fieldEditor"] valueForKey:@"_textStorage"];
            return st ? [NSString stringWithFormat:@"%s '%@'", object_getClassName(st), [st string]] : @"nil";
        } @catch (id e) {
            return [e description];
        }
    };
    shimlog(@"phonefield: phone field contentType %@, keyboard %ld, font %@, color %@, adjusts %d, placeholder '%@', "
            @"attrs %@, field storage '%@'", tf.textContentType, (long)tf.keyboardType, tf.font, tf.textColor,
            tf.adjustsFontSizeToFitWidth, tf.attributedPlaceholder.string, tf.defaultTextAttributes,
            [[tf valueForKey:@"_textStorage"] string]);
    @try {
        id fe = [tf valueForKey:@"_fieldEditor"];
        shimlog(@"phonefield: storages: field %p, field LM %p, editor %p, editor LM %p (field LM == editor LM: %d)",
                [tf valueForKey:@"_textStorage"], [[tf valueForKey:@"__layoutManager"] textStorage],
                [fe valueForKey:@"_textStorage"], [[fe valueForKey:@"__layoutManager"] textStorage],
                [tf valueForKey:@"__layoutManager"] == [fe valueForKey:@"__layoutManager"]);
        Ivar iv = class_getInstanceVariable(object_getClass(fe), "__textStorage");
        const uint8_t *weak = class_getWeakIvarLayout(object_getClass(fe));
        shimlog(@"phonefield: UIFieldEditor __textStorage at +%td, weak layout %s", iv ? ivar_getOffset(iv) : -1,
                weak ? "present" : "none");
    } @catch (id e) {
    }
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
    NSDictionary<NSString *, void (^)(void)> *steps = @{
        @"1 textColor": ^{ f.textColor = tf.textColor; },
        @"2 textContentType": ^{ f.textContentType = tf.textContentType; },
        @"3 keyboardType": ^{ f.keyboardType = tf.keyboardType; },
        @"4 font": ^{ f.font = tf.font; },
        @"5 adjustsFontSizeToFitWidth": ^{ f.adjustsFontSizeToFitWidth = tf.adjustsFontSizeToFitWidth; },
        @"6 attributedPlaceholder": ^{ f.attributedPlaceholder = tf.attributedPlaceholder; },
        @"7 defaultTextAttributes": ^{ f.defaultTextAttributes = tf.defaultTextAttributes; },
        @"8 text nil": ^{ f.text = nil; },
        @"9 text 7": ^{ f.text = @"7"; },
    };
    shimlog(@"phonefield: replay 0 fresh: %@", storage(f));
    for (NSString *k in [steps.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        @try {
            steps[k]();
            shimlog(@"phonefield: replay %@: %@", k, storage(f));
        } @catch (id e) {
            shimlog(@"phonefield: replay %@: threw %@", k, e);
        }
    }
    @try {
        id fe = [tf valueForKey:@"_fieldEditor"];
        for (Class k = object_getClass(fe); k && k != objc_getClass("UIScrollView"); k = class_getSuperclass(k))
            shimlog(@"phonefield: %s ivars:%@", class_getName(k), ivars(fe, k));
    } @catch (id e) {
    }
}

// Method defined by k itself (not inherited), NULL if none.
static Method ownMethod(Class k, const char *name) {
    unsigned n = 0;
    Method *ms = k ? class_copyMethodList(k, &n) : NULL, r = NULL;
    for (unsigned i = 0; i < n && !r; i++)
        if (!strcmp(sel_getName(method_getName(ms[i])), name)) r = ms[i];
    free(ms);
    return r;
}

// Caller frames as image+offset (WhatsApp VA = 0x100000000 + offset).
static NSString *backtrace(void) {
    NSMutableString *s = [NSMutableString string];
    NSArray<NSNumber *> *ra = [NSThread callStackReturnAddresses];
    for (NSUInteger i = 2; i < ra.count && i < 16; i++) {
        uintptr_t a = ra[i].unsignedLongValue;
        Dl_info di;
        if (dladdr((void *)a, &di) && di.dli_fname) {
            const char *img = strrchr(di.dli_fname, '/');
            [s appendFormat:@"\n    %s+0x%lx", img ? img + 1 : di.dli_fname, (unsigned long)(a - (uintptr_t)di.dli_fbase)];
        } else {
            [s appendFormat:@"\n    %p", (void *)a];
        }
    }
    return s;
}

static IMP hook(Class c, const char *name, id block) {
    Method m = c ? class_getInstanceMethod(c, sel_registerName(name)) : NULL;
    if (!m) {
        shimlog(@"phonefield: no %s on %s", name, c ? class_getName(c) : "(null)");
        return NULL;
    }
    return method_setImplementation(m, imp_implementationWithBlock(block));
}

__attribute__((constructor)) static void tracePhoneField(void) {
    Class field = objc_getClass("WAPhoneNumberTextField"), helper = objc_getClass("WAPhoneNumberTextFieldHelper");
    NSMutableString *chain = [NSMutableString string];
    for (Class k = field; k; k = class_getSuperclass(k)) [chain appendFormat:@" %s", class_getName(k)];
    shimlog(@"phonefield: WAPhoneNumberTextField:%@", chain);
    // injected tweaks (a text/keyboard tweak could be what empties the field)
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *p = _dyld_get_image_name(i);
        if (strstr(p, "MobileSubstrate") || strstr(p, "TweakInject") || !strncmp(p, "/Library/Frameworks/", 20) ||
            strstr(p, "substitute") || strstr(p, "libhooker") || strstr(p, "ellekit"))
            shimlog(@"phonefield: injected %s", p);
    }

    // who detaches the field editor's layout manager from its storage (the field's
    // storage is alive, its layout manager's textStorage nil): add/remove/replace on the
    // classes that define them, logged for _UIFieldEditorLayoutManager only
    Class felm = objc_getClass("_UIFieldEditorLayoutManager");
    const char *setters[][2] = {
        {"NSTextStorage", "addLayoutManager:"}, {"NSTextStorage", "removeLayoutManager:"},
        {"_UICascadingTextStorage", "addLayoutManager:"}, {"_UICascadingTextStorage", "removeLayoutManager:"},
        {"NSLayoutManager", "replaceTextStorage:"}, {"NSLayoutManager", "setTextStorage:"},
        {"_UIFieldEditorLayoutManager", "replaceTextStorage:"}, {"_UIFieldEditorLayoutManager", "setTextStorage:"},
    };
    for (size_t i = 0; i < sizeof setters / sizeof *setters; i++) {
        Method m = ownMethod(objc_getClass(setters[i][0]), setters[i][1]);
        if (!m) continue;
        SEL sel = method_getName(m);
        const char *cn = setters[i][0];
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, id arg) {
            if (object_getClass(self) == felm || object_getClass(arg) == felm)
                shimlog(@"phonefield: -[%s(%s) %s] %p <- %s %p%@", object_getClassName(self), cn, sel_getName(sel),
                        self, arg ? object_getClassName(arg) : "nil", arg, backtrace());
            ((void (*)(id, SEL, id))orig)(self, sel, arg);
        }));
    }
    static void (*initStorage)(id, SEL);
    initStorage = (void *)hook(objc_getClass("UITextField"), "_initTextStorage", ^(UITextField *self) {
        initStorage(self, sel_registerName("_initTextStorage"));
        @try {
            shimlog(@"phonefield: -[%s _initTextStorage] %p: storage %p%@", object_getClassName(self), self,
                    [self valueForKey:@"_textStorage"], backtrace());
        } @catch (id e) {
        }
    });

    static BOOL (*change)(id, SEL, id, NSRange, id);
    change = (void *)hook(helper, "textField:shouldChangeCharactersInRange:replacementString:",
                          ^BOOL(id self, id tf, NSRange r, NSString *s) {
        NSString *before = textOf(tf);
        BOOL ok = change(self, sel_registerName("textField:shouldChangeCharactersInRange:replacementString:"), tf, r, s);
        shimlog(@"phonefield: shouldChange %s %@ {%lu,%lu} '%@' -> %d, now %@", object_getClassName(tf), before,
                (unsigned long)r.location, (unsigned long)r.length, s, ok, textOf(tf));
        return ok;
    });

    static id (*sanitize)(id, SEL, id, BOOL);
    sanitize = (void *)hook(object_getClass(helper), "sanitizedReplacementString:preservingLeadingPlus:",
                            ^id(id self, NSString *s, BOOL plus) {
        id r = sanitize(self, sel_registerName("sanitizedReplacementString:preservingLeadingPlus:"), s, plus);
        shimlog(@"phonefield: sanitized '%@' plus %d -> '%@'", s, plus, r);
        return r;
    });

    // raw UIKit value around the start of editing
    static void (*begin)(id, SEL, id);
    begin = (void *)hook(helper, "textFieldDidBeginEditing:", ^(id self, UITextField *tf) {
        NSString *(*raw)(id, SEL) = (void *)method_getImplementation(
            class_getInstanceMethod(objc_getClass("UITextField"), @selector(text)));
        NSString *before = raw(tf, @selector(text));
        begin(self, sel_registerName("textFieldDidBeginEditing:"), tf);
        shimlog(@"phonefield: didBeginEditing raw text %@ -> %@ (editing %d)", before ? before : @"nil",
                raw(tf, @selector(text)) ?: @"nil", tf.isEditing);
    });

    static void (*setText)(id, SEL, id);
    setText = (void *)hook(field, "setText:", ^(id self, NSString *t) {
        setText(self, @selector(setText:), t);
        shimlog(@"phonefield: setText: '%@' -> %@ [%@]", t, textOf(self), uikitState(self));
        dumpOnce(self);
    });

    static id (*format)(id, SEL, id, BOOL);
    format = (void *)hook(field, "formattedFullOrLocalString:removingCountryCode:", ^id(id self, NSString *s, BOOL cc) {
        id r = format(self, sel_registerName("formattedFullOrLocalString:removingCountryCode:"), s, cc);
        shimlog(@"phonefield: formatted '%@' cc %d -> '%@'", s, cc, r);
        return r;
    });

    static void (*didChange)(id, SEL, id);
    didChange = (void *)hook(objc_getClass("WAPhoneInputViewController"), "phoneNumberTextFieldDidChange:",
                             ^(id self, id tf) {
        shimlog(@"phonefield: VC didChange %@", textOf(tf));
        didChange(self, sel_registerName("phoneNumberTextFieldDidChange:"), tf);
    });

    static void (*insert)(id, SEL, id);
    insert = (void *)hook(objc_getClass("UITextField"), "insertText:", ^(UITextField *self, NSString *t) {
        shimlog(@"phonefield: insertText '%@' into %s (delegate %s) %@", t, object_getClassName(self),
                object_getClassName(self.delegate), textOf(self));
        insert(self, @selector(insertText:), t);
    });
}
#endif
