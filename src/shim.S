// Runtime entry points from newer iOS (objc4, Swift, sqlite, StoreKit 2) missing on the
// target. Built by build-shim.sh. Semantics follow objc4-866 objc-msg-arm64.s:
// objc_{retain,release}_xN take the object in xN, then behave as objc_{retain,release}.

	.text
	.p2align 2

	.globl _objc_retain_x1
_objc_retain_x1:
	mov x0, x1
	b _objc_retain

	.globl _objc_release_x1
_objc_release_x1:
	mov x0, x1
	b _objc_release

	.globl _objc_retain_x2
_objc_retain_x2:
	mov x0, x2
	b _objc_retain

	.globl _objc_release_x2
_objc_release_x2:
	mov x0, x2
	b _objc_release

	.globl _objc_retain_x3
_objc_retain_x3:
	mov x0, x3
	b _objc_retain

	.globl _objc_release_x3
_objc_release_x3:
	mov x0, x3
	b _objc_release

	.globl _objc_retain_x4
_objc_retain_x4:
	mov x0, x4
	b _objc_retain

	.globl _objc_release_x4
_objc_release_x4:
	mov x0, x4
	b _objc_release

	.globl _objc_retain_x5
_objc_retain_x5:
	mov x0, x5
	b _objc_retain

	.globl _objc_release_x5
_objc_release_x5:
	mov x0, x5
	b _objc_release

	.globl _objc_retain_x6
_objc_retain_x6:
	mov x0, x6
	b _objc_retain

	.globl _objc_release_x6
_objc_release_x6:
	mov x0, x6
	b _objc_release

	.globl _objc_retain_x7
_objc_retain_x7:
	mov x0, x7
	b _objc_retain

	.globl _objc_release_x7
_objc_release_x7:
	mov x0, x7
	b _objc_release

	.globl _objc_retain_x8
_objc_retain_x8:
	mov x0, x8
	b _objc_retain

	.globl _objc_release_x8
_objc_release_x8:
	mov x0, x8
	b _objc_release

	.globl _objc_retain_x9
_objc_retain_x9:
	mov x0, x9
	b _objc_retain

	.globl _objc_release_x9
_objc_release_x9:
	mov x0, x9
	b _objc_release

	.globl _objc_retain_x10
_objc_retain_x10:
	mov x0, x10
	b _objc_retain

	.globl _objc_release_x10
_objc_release_x10:
	mov x0, x10
	b _objc_release

	.globl _objc_retain_x11
_objc_retain_x11:
	mov x0, x11
	b _objc_retain

	.globl _objc_release_x11
_objc_release_x11:
	mov x0, x11
	b _objc_release

	.globl _objc_retain_x12
_objc_retain_x12:
	mov x0, x12
	b _objc_retain

	.globl _objc_release_x12
_objc_release_x12:
	mov x0, x12
	b _objc_release

	.globl _objc_retain_x13
_objc_retain_x13:
	mov x0, x13
	b _objc_retain

	.globl _objc_release_x13
_objc_release_x13:
	mov x0, x13
	b _objc_release

	.globl _objc_retain_x14
_objc_retain_x14:
	mov x0, x14
	b _objc_retain

	.globl _objc_release_x14
_objc_release_x14:
	mov x0, x14
	b _objc_release

	.globl _objc_retain_x15
_objc_retain_x15:
	mov x0, x15
	b _objc_retain

	.globl _objc_release_x15
_objc_release_x15:
	mov x0, x15
	b _objc_release

	.globl _objc_retain_x19
_objc_retain_x19:
	mov x0, x19
	b _objc_retain

	.globl _objc_release_x19
_objc_release_x19:
	mov x0, x19
	b _objc_release

	.globl _objc_retain_x20
_objc_retain_x20:
	mov x0, x20
	b _objc_retain

	.globl _objc_release_x20
_objc_release_x20:
	mov x0, x20
	b _objc_release

	.globl _objc_retain_x21
_objc_retain_x21:
	mov x0, x21
	b _objc_retain

	.globl _objc_release_x21
_objc_release_x21:
	mov x0, x21
	b _objc_release

	.globl _objc_retain_x22
_objc_retain_x22:
	mov x0, x22
	b _objc_retain

	.globl _objc_release_x22
_objc_release_x22:
	mov x0, x22
	b _objc_release

	.globl _objc_retain_x23
_objc_retain_x23:
	mov x0, x23
	b _objc_retain

	.globl _objc_release_x23
_objc_release_x23:
	mov x0, x23
	b _objc_release

	.globl _objc_retain_x24
_objc_retain_x24:
	mov x0, x24
	b _objc_retain

	.globl _objc_release_x24
_objc_release_x24:
	mov x0, x24
	b _objc_release

	.globl _objc_retain_x25
_objc_retain_x25:
	mov x0, x25
	b _objc_retain

	.globl _objc_release_x25
_objc_release_x25:
	mov x0, x25
	b _objc_release

	.globl _objc_retain_x26
_objc_retain_x26:
	mov x0, x26
	b _objc_retain

	.globl _objc_release_x26
_objc_release_x26:
	mov x0, x26
	b _objc_release

	.globl _objc_retain_x27
_objc_retain_x27:
	mov x0, x27
	b _objc_retain

	.globl _objc_release_x27
_objc_release_x27:
	mov x0, x27
	b _objc_release

	.globl _objc_retain_x28
_objc_retain_x28:
	mov x0, x28
	b _objc_retain

	.globl _objc_release_x28
_objc_release_x28:
	mov x0, x28
	b _objc_release

// iOS 16 variant without the mov x29,x29 handshake; iOS 14 callee then does a real
// autorelease and this falls back to a plain retain -> same +1 result.
	.globl _objc_claimAutoreleasedReturnValue
_objc_claimAutoreleasedReturnValue:
	b _objc_retainAutoreleasedReturnValue

// sqlite 3.37+: 64-bit change count.
	.globl _sqlite3_changes64
_sqlite3_changes64:
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	bl _sqlite3_changes
	sxtw x0, w0
	ldp x29, x30, [sp], #16
	ret

// Swift 5.6 runtime: false = never stack-allocate, use heap (always safe).
	.globl _swift_stdlib_isStackAllocationSafe
_swift_stdlib_isStackAllocationSafe:
	mov w0, #0
	ret

// StoreKit 2 (iOS 15): AppStore.deviceVerificationID -> Optional<UUID>.none.
// Optional<UUID> is 17 bytes, returned indirectly via x8: 16 payload bytes + tag byte 1.
	.globl "_$s8StoreKit03AppA0O20deviceVerificationID10Foundation4UUIDVSgvgZ"
"_$s8StoreKit03AppA0O20deviceVerificationID10Foundation4UUIDVSgvgZ":
	stp xzr, xzr, [x8]
	mov w9, #1
	strb w9, [x8, #16]
	ret

// UIKit overlay (15): UIAction(title:subtitle:image:identifier:discoverabilityTitle:attributes:
// state:handler:) -> the 14 init without subtitle (14 menus show none; the owned subtitle
// String? is released). In: x0/x1 title, x2/x3 subtitle, x4 image, x5 identifier, x6/x7
// discoverabilityTitle, stack: attributes, state, handler fn, handler ctx; metatype in x20.
// Target: x0/x1 title, x2 image, x3 identifier, x4/x5 discoverabilityTitle, x6 attributes,
// x7 state, stack: handler fn, ctx. Incoming stack args are at sp+112 after the prologue.
	.globl "_$sSo8UIActionC5UIKitE5title8subtitle5image10identifier20discoverabilityTitle10attributes5state7handlerABSS_SSSgSo7UIImageCSgSo0A10IdentifieraSgALSo23UIMenuElementAttributesVSo0nO5StateVyABctcfC"
"_$sSo8UIActionC5UIKitE5title8subtitle5image10identifier20discoverabilityTitle10attributes5state7handlerABSS_SSSgSo7UIImageCSgSo0A10IdentifieraSgALSo23UIMenuElementAttributesVSo0nO5StateVyABctcfC":
	sub sp, sp, #112
	stp x29, x30, [sp, #16]
	add x29, sp, #16
	stp x0, x1, [sp, #32]
	stp x4, x5, [sp, #48]
	stp x6, x7, [sp, #64]
	mov x0, x3
	bl _swift_bridgeObjectRelease
	ldp x0, x1, [sp, #32]
	ldp x2, x3, [sp, #48]
	ldp x4, x5, [sp, #64]
	ldp x6, x7, [sp, #112]
	ldp x9, x10, [sp, #128]
	stp x9, x10, [sp]
	bl "_$sSo8UIActionC5UIKitE5title5image10identifier20discoverabilityTitle10attributes5state7handlerABSS_So7UIImageCSgSo0A10IdentifieraSgSSSgSo23UIMenuElementAttributesVSo0mN5StateVyABctcfC"
	ldp x29, x30, [sp, #16]
	add sp, sp, #112
	ret

// Swift Dispatch (iOS 15 SDK): DispatchWorkItem.init(flags:block:) -> the 14 init(qos:flags:block:)
// with qos .unspecified. Resilient structs are passed by address: x0 = &flags, x1 = block
// (owned), self in x20; target takes x0 = &qos, x1 = &flags, x2 = block.
// DispatchQoS = {QoSClass tag (5 = .unspecified -> QOS_CLASS_UNSPECIFIED), relativePriority}.
	.globl "_$s8Dispatch0A8WorkItemC5flags5blockAcA0abC5FlagsV_yyXBtcfc"
"_$s8Dispatch0A8WorkItemC5flags5blockAcA0abC5FlagsV_yyXBtcfc":
	mov x2, x1
	mov x1, x0
	adrp x0, Lqos_unspecified@PAGE
	add x0, x0, Lqos_unspecified@PAGEOFF
	b "_$s8Dispatch0A8WorkItemC3qos5flags5blockAcA0A3QoSV_AA0abC5FlagsVyyXBtcfc"

	.section __TEXT,__const
	.p2align 3
Lqos_unspecified:
	.quad 5
	.quad 0
	.text

// Foundation overlay (14.5): URLRequest.assumesHTTP3Capable setter. An HTTP/3 hint 14
// doesn't have: ignored (mutating setter: w0 = value, self in x20).
	.globl "_$s10Foundation10URLRequestV19assumesHTTP3CapableSbvs"
"_$s10Foundation10URLRequestV19assumesHTTP3CapableSbvs":
	ret

// CoreData overlay (15): NSManagedObjectContext.performAndWait<T>(_:) (generic, rethrows).
// Swift ABI: x0/x1 = closure fn/context, x2 = T metadata, x8 = indirect result, self in
// x20, error out in x21. -> waport_moc_performAndWait(self, fn, ctx, out) in cfuncs.m.
	.globl "_$sSo22NSManagedObjectContextC8CoreDataE14performAndWaityxxyKXEKlF"
"_$sSo22NSManagedObjectContextC8CoreDataE14performAndWaityxxyKXEKlF":
	stp x29, x30, [sp, #-16]!
	mov x29, sp
	mov x3, x8
	mov x2, x1
	mov x1, x0
	mov x0, x20
	bl _waport_moc_performAndWait
	mov x21, x0
	ldp x29, x30, [sp], #16
	ret

// Call a Swift closure `() throws -> T` (T indirect): x0 = fn, x1 = context, x2 = result
// buffer. Returns the thrown error (or 0) in x0.
	.globl _waport_swift_call
_waport_swift_call:
	stp x29, x30, [sp, #-32]!
	mov x29, sp
	stp x20, x21, [sp, #16]
	mov x16, x0
	mov x20, x1
	mov x8, x2
	mov x21, #0
	blr x16
	mov x0, x21
	ldp x20, x21, [sp, #16]
	ldp x29, x30, [sp], #32
	ret
	.text

// overlays.swift imports UIKit through the iOS 15.6 SDK interfaces, which autolink two
// 15-only overlays: their force-load anchors (link-time only, nothing of them is used).
	.section __DATA,__const
	.p2align 3
	.private_extern "__swift_FORCE_LOAD_$_swiftFileProvider"
	.globl "__swift_FORCE_LOAD_$_swiftFileProvider"
"__swift_FORCE_LOAD_$_swiftFileProvider":
	.quad 0
	.private_extern "__swift_FORCE_LOAD_$_swiftDataDetection"
	.globl "__swift_FORCE_LOAD_$_swiftDataDetection"
"__swift_FORCE_LOAD_$_swiftDataDetection":
	.quad 0
	.text

