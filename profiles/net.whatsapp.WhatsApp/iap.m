// In-app purchases (subscriptions, Meta Verified, ...) are StoreKit 2 (iOS 15): Transaction,
// VerificationResult etc. don't exist on 14, and a launch task that looks up
// VerificationResult<Transaction>? gets null metadata -> crash. Disabled:
// - -[IAPStartupCoordinator registerAll] / -reactivateAfterAccountSwitch: no-ops.
// - IAPStartupKit2.IAPTransactionObserver (Transaction.updates listener, started per user
//   session through FOAUserSession.releasableScopedObjects): its start is pure Swift,
//   reached through a function table entry; that entry is pointed at a no-op. Offsets are
//   for 26.41.74 and checked before writing.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

#include "waport.h"

static void noop(void) {}

// Replace the pointer at main-executable offset `slot` if it still points at `expected`.
static void replaceTableEntry(const char *what, uintptr_t slot, uintptr_t expected, void *repl) {
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    void **p = (void **)(base + slot);
    if ((uintptr_t)*p != base + expected) {
        shimlog(@"IAP: %s: entry at +0x%lx is +0x%lx, not +0x%lx (other version?), left alone", what,
                (unsigned long)slot, (unsigned long)((uintptr_t)*p - base), (unsigned long)expected);
        return;
    }
    vm_address_t page = (vm_address_t)p & ~(vm_page_size - 1);
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *p = repl;
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ);
    shimlog(@"IAP: %s disabled", what);
}

__attribute__((constructor)) static void disableIAPStartup(void) {
    // the table offset is the main app's (extensions load the shim too)
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"net.whatsapp.WhatsApp"]) return;
    Class c = objc_getClass("IAPStartupCoordinator");
    const char *sels[] = {"registerAll", "reactivateAfterAccountSwitch"};
    for (size_t i = 0; i < sizeof sels / sizeof *sels; i++) {
        Method m = c ? class_getInstanceMethod(c, sel_registerName(sels[i])) : NULL;
        if (!m) { shimlog(@"IAP: -[IAPStartupCoordinator %s] not found", sels[i]); continue; }
        const char *name = sels[i];
        method_setImplementation(m, imp_implementationWithBlock(^(id self) {
            shimlog(@"IAP: -[IAPStartupCoordinator %s] skipped (StoreKit 2)", name);
        }));
    }
    replaceTableEntry("IAPTransactionObserver start", 0x8089488, 0x120474C, (void *)noop);
}
