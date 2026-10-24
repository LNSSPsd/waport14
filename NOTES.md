# Technical notes

This file covers what the port changes and why. WhatsApp-specific findings are in
`profiles/net.whatsapp.WhatsApp/NOTES.md`. What doesn't depend on WhatsApp is kept here, so
it can be reused if another app is ported later; so far it has only been tested with
WhatsApp 26.41.74.

## Principles

- **Derived from the target's own dyld cache at build time**: an import is only touched if
  the target doesn't export it.
- **Bundle ID and entitlements unchanged** (each image re-signed with its own), so the
  install must go through TrollStore. One addition: app extensions get
  `com.apple.private.memorystatus` (see `memlimit.m`).
- **Nothing on disk that the old dyld rejects**: `verify.py` re-checks every image,
  including dlopen'd frameworks and app extensions.
- **Prefer a loud failure to a silent one**: a missing function becomes a named trap, not a
  jump to address 0.

## Load-time fixes (tools/patch.py)

| Problem | Fix |
|---|---|
| `LC_BUILD_VERSION` minos / `MinimumOSVersion` too new | → `TARGET_IOS`; also drop `UISupportedDevices` (App Store thinning) |
| Pointer format 6 (`DYLD_CHAINED_PTR_64_OFFSET`, iOS 15+ linker output for min ≥ 15.x/16) | convert to format 2. Min-15.1 builds (WhatsApp) already use format 2 |
| System dylib absent (`libswift_Concurrency` < 15, `AVFAudio` < 14.5, iOS 16+ frameworks such as AppIntents and Charts) | Concurrency → bundled Swift 5.5 back-deploy runtime (`@rpath` + `LC_RPATH /usr/lib/swift`); any other → weak load |
| Symbol moved between dylibs | `RETARGETS`: Foundation → `libswiftFoundation` (Swift overlay before 15), AVFAudio → AVFoundation |
| Function the target lacks | the shim's real implementation if there is one; else a generated **trap** |
| Swift async function pointer the target lacks | generated `{rel32 → trap, 64}` |
| Swift resilient enum case tag the target lacks | generated `u32 0` (the read succeeds, the API's trap reports) |
| Data the target lacks (metadata, descriptors, ObjC classes) | weak null: the runtimes treat it as weak-linked and absent |
| Already-weak import the target lacks | unchanged: the app guards it with `#available` or a null check, and a trap would break the null check |
| Weak-lookup imports (chained ordinal −3, ld-prime `operator new/delete`, …) | → the dylib that exports them (14's dyld2 leaves them null) |
| Classic-bind images: weak-bind-only symbols | explicit binds appended. dyld2 checks LINKEDIT order, see `machotool.append_binds` |
| ExtensionKit `Extensions/*.appex` (iOS 16+) | removed |
| Executables | + `LC_LOAD_DYLIB @rpath/libwaport.dylib`, so the ObjC fallbacks are installed in app extensions too |

**Function or data?** For C/ObjC names, an import is a function if `__stubs` jumps through
its GOT slot (`machotool.stub_imports`). Name heuristics got constants such as
`AVCaptureISOAuto` wrong. Swift names are classified by their demangling.

## Runtime (src/)

| File | |
|---|---|
| `shim.S` | iOS 16 objc4 entry points (`objc_retain_xN`, …), `sqlite3_changes64`, `swift_stdlib_isStackAllocationSafe`, StoreKit `AppStore.deviceVerificationID` → nil |
| `cfuncs.m` | `SecTrustCopyCertificateChain`, `CVBufferCopyAttachment(s)`, `CMTimebaseCreateWithSourceClock`, `swift_getFunctionTypeMetadataGlobalActor` → back-deploy `…Standalone`, … |
| `consts.m` | newer string/struct constants. A nil key in a dictionary literal throws, so these must not stay null |
| `compat.m` | add-if-missing fallbacks for iOS 15/16 ObjC methods (candidates from `tools/scan_objc.py`) |
| `swiftnative.m` | `SwiftNativeNSObject` (Swift 5.5 runtime class, superclass of `@objc` actors). Without it, iOS 14 drops the subclasses |
| `mangle.m` | Swift 5.5 Concurrency substitutions (`ScP`, `ScT`, `ScM`, …) in runtime type names: the 5.3 runtime can't demangle them, so lookups return null. 5.5 function attributes `Yb` (@Sendable), `Ya` (async) and `ScMYc` (@MainActor) are worse: 5.3 returns the *last parsed node* (a wrong, non-null type), so names holding them are always rewritten with the attribute dropped, and the rewritten result wins. Identifiers (`<len><chars>`) are skipped while scanning (`UIWindowScene` contains `Sc`+`e`). The app's `swift_getTypeByMangledName*` imports are bound here and retried with `Swift.<Name>` spelled out (the Concurrency library's ABI module name is `Swift`, not `_Concurrency`); embedded relative symbolic references are re-encoded into an arena within int32 range. Spelling a substitution out adds substitution entries and words, so the name is tokenized (Demangler.cpp rules) and `A<n>` back-references renumbered, word-substituted identifiers written out in full; unknown tokens fail the rewrite (logged `can't rewrite`) |
| `overlays.swift` | iOS 15 Swift overlay APIs whose types the app instantiates (resilient structs, async functions), too much for assembly: written in Swift and exported under the overlay's symbol names with `@_silgen_name`. `-enable-library-evolution` keeps the overlay ABI (resilient types indirect, `self` by address); check the signatures in `-emit-ir` against the overlay's. Members `@_silgen_name` can't name (metadata accessors, inits, getters, enum case tags) are given the overlay's name with `ld -alias_list` (`src/overlays.aliases`). Built with theos' swift-5.8 toolchain against the iOS 15.6 SDK interfaces, target 14.0; links the back-deployed `@rpath/libswift_Concurrency` (the app bundles it) and the compatibility archives. The compiler avoids Concurrency manglings for a 14 target (symbolic references / accessors). So far: `NotificationCenter.notifications(named:object:)`, `Date.now`, async `URLSession` data/download, diffable data source 15 methods, `OSSignposter`, `UIButton.Configuration` (applied with the legacy `UIButton` API; no state updates) with `UIConfigurationTextAttributesTransformer` on a minimal `AttributeContainer`, `URLSession.bytes(for:delegate:)` (private session with our data delegate, challenges forwarded; the app inlines the `@frozen` `_AsyncBytesBuffer` reads) (class methods: name the dispatch thunk `…Tj`, async ones get `…TjTu`). Importing UIKit autolinks the 15-only FileProvider/DataDetection overlays: their `__swift_FORCE_LOAD_$_…` anchors are dummies in `shim.S`. Check an implementation's ABI by compiling a reference file that calls the real API (15.6 SDK, `@available(iOS 15, *)`) with `-emit-ir` and comparing its `declare` lines with ours |
| `memlimit.m` | App extensions raise their own jetsam limit to 64 MB (`memorystatus_control`, allowed by the `com.apple.private.memorystatus` entitlement `patch.py` adds to them). Extensions run under small limits (notification service: 24 MB) and jetsam kills without a signal. iOS 14's dyld binds every data page at load (dirty, counted), so an extension linking a large framework of an app built for a newer iOS starts near its limit |
| `tweaks.m` | Injected jailbreak tweaks that enumerate all classes (FLEX): `objc_copyClassList` / `objc_getClassList` realize every class, and some of the app's Swift classes have metadata inits that call already-weak accessors of newer types (null on 14). Both are rebound in every non-cache, non-bundle image (symbol-pointer sections) to list only classes of images outside the app bundle |
| `log.m` | `waport.log`, `waport_trap`, diagnostics: fatal-signal backtraces, with the app's own signal handlers wrapped through `sigaction`/`signal` hooks |

### Missing ObjC methods

A build with minimum iOS N drops every `@available` check for APIs ≤ N, so methods from
iOS 15.0–N are sent unguarded. `scan_objc.py` intersects the app's selectors with methods
the 16.5 SDK annotates as `ios(15.0/15.1)` and the 14.5 SDK doesn't declare on that class.
Watch for **name collisions**: `scrollEdgeAppearance` is iOS 13 on `UINavigationBar` but 15
on `UIToolbar`. Whole new classes don't matter: they're nil, and messaging nil is a no-op.

Notable fallbacks: `UIView.keyboardLayoutGuide` is a real layout guide that tracks the
keyboard frame. `reconfigureRows/Items` → reload without animation. `UIButton`
configuration APIs: there's no `UIButtonConfiguration` on 14, so nibs get a decoding stub
that applies the title, image and colour the legacy way.

## Not handled yet

- Concurrency substitutions in type names the **runtime itself** demangles (associated
  type witnesses, key paths, reflection) don't go through the app's imports. The full fix
  is the runtime's `__swift53_hooks` override table, which 14.3 reads only from the main
  executable.

- **Swift overlay APIs from iOS 15** not in `overlays.swift` yet (`AttributedString`, so also
  `UIButton.Configuration.attributedTitle`, `FormatStyle`, SwiftUI 3 such as `FocusState` and
  `.task`, StoreKit 2) are traps. If an app's main path hits one, implement it in
  `overlays.swift` (or, for a thin wrapper, as a Swift-ABI thunk in `shim.S`: `self` in x20,
  async context in x22).
- Classic-bind images: unresolved imports are only reported (by `verify.py`), not rewritten.
- Fat binaries: thin them first.
- Only tested against the 14.3 cache.

## Tools

- `ipsw dyld tbd` fails on the 14.3 cache (objc relative-method parse error). `dyldex`
  (dyldextractor) works.
- `swift-demangle` is in theos' swift-5.8 toolchain (`toolchain/swift-5.8/linux/host/bin`).
