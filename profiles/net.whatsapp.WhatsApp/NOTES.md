# WhatsApp Messenger (net.whatsapp.WhatsApp)

**Input:** 26.41.74, `MinimumOSVersion` 15.1, Xcode 27 / iOS 27.0 SDK. Chained fixups are
already pointer format 2.

## Bundle

| Image | Notes |
|---|---|
| `WhatsApp` | 42.6k imports, links `SharedModules` |
| `Frameworks/SharedModules.framework` | 80 MB core, used by the app and every appex |
| `Frameworks/PsiphonTunnel.framework` | dlopen'd (censorship-circumvention proxy) |
| `Frameworks/CommonLibrary.framework` | classic binds, min 13.0, India UPI payments |
| `PlugIns/ServiceExtension.appex` | notification service: decrypts pushes. **Matters for message notifications** (delivered while the app is not running). Links `SharedModules`, whose bound data pages (~14 MB dirty) put it at ~19 MB of its 24 MB limit at launch: needs the raised limit (`memlimit.m`) |
| `PlugIns/{Notification,Share,Intents,Widget,BroadcastUpload}Extension.appex` | |
| `Extensions/{AppMigration,NPCIPayments}Extension.appex` | ExtensionKit, iOS 26: removed |

## Missing on 14.3 (first build)

536 symbols the app calls unguarded: 361 traps, 23 async traps, 39 enum-case zeros, 113 weak data.
Call sites are sparse: about 380 total for all missing symbols (`tools/callsites.py`). By
API:

- StoreKit 2 (`Product`, `Transaction`, `Storefront`): about 140, payments and subscriptions.
  **Risk:** a `Transaction.updates` listener started at launch would trap immediately.
- Foundation `Date.FormatStyle` / `IntegerFormatStyle` / `AttributedString` /
  async `URLSession` / `NotificationCenter.notifications`: about 100
- UIKit Swift overlay `UIButton.Configuration`, cell `configurationUpdateHandler`, list
  separator configuration: about 60
- SwiftUI 3 (`FocusState`, `TimelineView`, `.task`, `dismiss`, styles): about 40
- `AVAsyncProperty` (async asset loading), CloudKit result blocks, `OSSignposter`,
  PhotosUI picker selection, CoreData `perform(schedule:)`
- Widget extension: AppIntents and WidgetKit 16+, many traps. Widgets may not work.

Resolved properly: Swift Concurrency (all of it, by the 5.5 back-deploy),
AVFAudio → AVFoundation (116), `SwiftNativeNSObject`, `swift_getFunctionTypeMetadataGlobalActor`,
`SecTrustCopyCertificateChain`, VideoToolbox LTR / constrained-profile keys (VoIP video).

## Status

Works on iOS 14.3 (tested with the diagnostic build): launch, registration
(phone number, profile name, two-step verification), chat list, chats.

Not implemented yet; a screen that reaches one of these may crash (and logs a `TRAP` naming
the API):

- UIKit `UIButton.Configuration` (about 60 call sites), cell `configurationUpdateHandler`,
  list separator configuration
- Foundation `FormatStyle` (dates, numbers), `AttributedString`, `URLSession.bytes`
- StoreKit 2 screens (purchases are disabled, see `iap.m`), SwiftUI 3, CoreData
  `perform(schedule:)`, widgets (AppIntents / WidgetKit 16+)

## Profile sources

| File | |
|---|---|
| `safemode.m` | diagnostic builds: resets WhatsApp's crash-loop counters at launch, else every crash while porting pushes it into its safe mode ("Couldn't open WhatsApp" / black screen) |
| `aibutton.m` | the Meta AI chat-list button is built on `UIButton.Configuration`: removed |
| `iap.m` | StoreKit 2 purchase startup disabled (`Transaction.updates` listener, a function-table entry checked against 26.41.74 offsets) |
| `phonefield.m` | registration phone field: its layout manager was created before UIKit 14's `_initTextStorage` (WhatsApp's `setFrame:` override reformats during init) and never attached, so typing had no effect; diagnostic builds trace the field's edit path |

Generic fixes this app needed are in `src/` (`mangle.m` substitution rewriting and
back-reference renumbering, `overlays.swift` Swift overlay APIs, `tweaks.m` for class-list
tweaks); see the top-level `NOTES.md`.
