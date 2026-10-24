// Swift 5.5 Concurrency standard substitutions (ScP = TaskPriority, ScT = Task, ...) in
// runtime type names. Code built for iOS 15+ uses them; the 14 runtime (Swift 5.3)
// can't demangle them, so lookups return null. The app's calls to the runtime's
// type-by-name entry points are bound here (patch.py HOOKS): on a null result, retry
// with the substitutions spelled out. The Concurrency library is built with ABI module
// name "Swift", so ScP = s12TaskPriorityV (Swift.TaskPriority), not _Concurrency.<Name>.
//
// Swift 5.5 function-type attributes are dropped: `Yb` (@Sendable), `Ya` (async) and
// `ScMYc` (global actor @MainActor), which 5.3 can't represent (an async closure has the
// same layout as a plain one: function pointer + context). 5.3 doesn't fail on these: its demangler
// returns the last node it parsed, e.g. `_ContiguousArrayStorage<@MainActor (A) -> B>`
// resolved to B's class metadata, and the app allocated its array buffers as B.
// So a name holding any of these is always rewritten, and the rewritten result wins when
// it resolves. (Metadata built directly through swift_getFunctionTypeMetadataGlobalActor
// keeps the actor, so the two spellings are distinct types to dynamic casts.)
//
// Identifiers (`<length><chars>`, e.g. `13UIWindowScene`) are copied unscanned: `Sc`+letter
// or `Yb` inside a name is not a substitution (`UIWindowScene` once became
// `UIWindows21UnownedSerialExecutorVne`).
//
// Spelling a substitution out shifts the name's back-references. The demangler numbers
// identifiers, nominal types (`C` `V` `O` `P` `a`), bound generics (`G`), `Sg`, context
// symbolic references and associated/opaque types in parse order, `A<index>` refers to
// that list, and a `0`-prefixed identifier reuses words of earlier identifiers. Standard
// substitutions (`Si`, `ScC`) aren't numbered, but `s19CheckedContinuationV` adds two
// entries and two words: in `ScCy<02>yyt<02>_pGAB_pG` the `AB` (the error protocol) came
// to mean CheckedContinuation itself, a wrong non-null type (a crash in
// resume(returning:)). So names are tokenized as in Demangler.cpp, back-references are
// renumbered and word-substituted identifiers written out in full; a token it doesn't
// know (entities, conformances, requirements) fails the rewrite (logged).
//
// Names may embed relative symbolic references (0x01-0x17 + int32 offset from the
// field), so the rewritten copy is placed in an arena within int32 range of the
// original and each reference is re-encoded.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <string.h>

#include "waport.h"

#define EXPORT __attribute__((visibility("default")))

static const struct { char c; const char *name; char kind; } kSubst[] = {
    {'A', "Actor", 'P'}, {'C', "CheckedContinuation", 'V'}, {'c', "UnsafeContinuation", 'V'},
    {'E', "CancellationError", 'V'}, {'e', "UnownedSerialExecutor", 'V'}, {'F', "Executor", 'P'},
    {'f', "SerialExecutor", 'P'}, {'G', "TaskGroup", 'V'}, {'g', "ThrowingTaskGroup", 'V'},
    {'I', "AsyncIteratorProtocol", 'P'}, {'i', "AsyncSequence", 'P'}, {'J', "UnownedJob", 'V'},
    {'M', "MainActor", 'C'}, {'P', "TaskPriority", 'V'}, {'S', "AsyncStream", 'V'},
    {'s', "AsyncThrowingStream", 'V'}, {'T', "Task", 'V'}, {'t', "UnsafeCurrentTask", 'V'},
};

static const char *expansion(char c) {
    static char buf[sizeof kSubst / sizeof *kSubst][64];
    for (size_t i = 0; i < sizeof kSubst / sizeof *kSubst; i++)
        if (kSubst[i].c == c) {
            if (!buf[i][0])
                snprintf(buf[i], sizeof buf[i], "s%zu%s%c", strlen(kSubst[i].name),
                         kSubst[i].name, kSubst[i].kind);
            return buf[i];
        }
    return NULL;
}

// --- arenas near the names (int32 reach for re-encoded references) ---------------
#define ARENA_SIZE (1 << 20)
static struct { uintptr_t base, used; } arenas[32];
static int narenas;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;

static bool near(uintptr_t a, uintptr_t b) {
    intptr_t d = (intptr_t)(a - b);
    return d > -(1L << 30) && d < (1L << 30);
}

static char *arenaAlloc(uintptr_t nearTo, size_t len) {
    for (int i = 0; i < narenas; i++)
        if (near(arenas[i].base, nearTo) && arenas[i].used + len <= ARENA_SIZE) {
            char *p = (char *)arenas[i].base + arenas[i].used;
            arenas[i].used += (len + 7) & ~7UL;
            return p;
        }
    if (narenas == sizeof arenas / sizeof *arenas) return NULL;
    // probe free address space in 16 MB steps above, then below, the name
    for (int dir = 1; dir >= -1; dir -= 2)
        for (long k = 1; k < 60; k++) {
            vm_address_t a = ((nearTo & ~0xFFFFFFUL) + dir * k * 0x1000000UL);
            if (vm_allocate(mach_task_self(), &a, ARENA_SIZE, VM_FLAGS_FIXED) == KERN_SUCCESS) {
                arenas[narenas].base = a;
                arenas[narenas].used = (len + 7) & ~7UL;
                narenas++;
                return (char *)a;
            }
        }
    return NULL;
}

// Gives back the unused tail of the last allocation.
static void arenaTrim(char *p, size_t cap, size_t used) {
    for (int i = 0; i < narenas; i++)
        if ((uintptr_t)p + ((cap + 7) & ~7UL) == arenas[i].base + arenas[i].used)
            arenas[i].used = (uintptr_t)p - arenas[i].base + ((used + 7) & ~7UL);
}

// Length of the 5.5-only construct at name[i] that is dropped (0 if none).
static size_t dropped(const char *name, size_t i, size_t len) {
    if (i + 5 <= len && !memcmp(name + i, "ScMYc", 5)) return 5;
    if (i + 2 <= len && name[i] == 'Y' && (name[i + 1] == 'b' || name[i + 1] == 'a')) return 2;
    return 0;
}

// Pre-filter only (rewriteInto does the real parse).
// Length of the identifier (decimal length + that many chars) at name[i], 0 if none. A
// number followed by '_' is an index (substitution A12_, generic parameter), not a length.
static size_t identifier(const char *name, size_t i, size_t len) {
    if (name[i] < '1' || name[i] > '9' || (i && name[i - 1] >= '0' && name[i - 1] <= '9')) return 0;
    size_t j = i, n = 0;
    while (j < len && name[j] >= '0' && name[j] <= '9' && n < 100000) n = n * 10 + (name[j++] - '0');
    if (j >= len || name[j] == '_' || j + n > len) return 0;
    return j - i + n;
}

static size_t symref(unsigned char c) {
    return c >= 0x01 && c <= 0x17 ? 5 : c >= 0x18 && c <= 0x1F ? 9 : 0;
}

static bool needsRewrite(const char *name, size_t len) {
    for (size_t i = 0; i < len;) {
        size_t r = symref(name[i]);
        if (!r) r = identifier(name, i, len);
        if (r) { i += r; continue; }
        if (dropped(name, i, len)) return true;
        if (i + 2 < len && name[i] == 'S' && name[i + 1] == 'c' && expansion(name[i + 2])) return true;
        i++;
    }
    return false;
}

#if WAPORT_LOG
static NSString *printable(const char *n, size_t len);
#endif

// --- tokenizer (Demangler::demangleOperator and helpers, type manglings only) --------
#define MAXSUBST 1024
typedef struct {
    const char *in;
    size_t len, i;
    char *out;
    size_t cap, o;
    int map[MAXSUBST], nsub, nnew;     // original substitution index -> rewritten index
    const char *word[26];
    size_t wlen[26];
    int nwords;
    bool changed, bad;
} RW;

static bool isDigit(char c) { return c >= '0' && c <= '9'; }
static bool isLower(char c) { return c >= 'a' && c <= 'z'; }
static bool isUpper(char c) { return c >= 'A' && c <= 'Z'; }

static char peek(RW *s) { return s->i < s->len ? s->in[s->i] : 0; }
static char next(RW *s) { return s->i < s->len ? s->in[s->i++] : 0; }
static bool nextIf(RW *s, char c) { return peek(s) == c && c ? (s->i++, true) : false; }

static void put(RW *s, const void *p, size_t n) {
    if (s->o + n > s->cap) { s->bad = true; return; }
    memcpy(s->out + s->o, p, n);
    s->o += n;
}

static void sub(RW *s) {
    if (s->nsub == MAXSUBST) { s->bad = true; return; }
    s->map[s->nsub++] = s->nnew++;
}

static int natural(RW *s) {
    if (!isDigit(peek(s))) return -1;
    int n = 0;
    while (isDigit(peek(s)))
        if ((n = n * 10 + (next(s) - '0')) > 1 << 20) { s->bad = true; return -1; }
    return n;
}

static void index_(RW *s) {                      // demangleIndex: `_` or `<n>_`
    if (nextIf(s, '_')) return;
    if (natural(s) < 0 || !nextIf(s, '_')) s->bad = true;
}

static void paramIndex(RW *s) {                  // demangleGenericParamIndex
    if (nextIf(s, 'd')) index_(s), index_(s);
    else if (!nextIf(s, 'z')) index_(s);
}

static void addWords(RW *s, const char *p, size_t n) {
    long start = -1;
    for (size_t k = 0; k <= n; k++) {
        char c = k < n ? p[k] : 0;
        if (start >= 0 && (c == '_' || !c || (!isUpper(p[k - 1]) && isUpper(c)))) {
            if (k - start >= 2 && s->nwords < 26)
                s->word[s->nwords] = p + start, s->wlen[s->nwords++] = k - start;
            start = -1;
        }
        if (start < 0 && c && c != '_' && !isDigit(c)) start = k;
    }
}

static void identifier_(RW *s) {
    size_t from = s->i;
    bool words = false, puny = false;
    if (nextIf(s, '0')) {
        if (nextIf(s, '0')) puny = true;
        else words = true;
    }
    bool hadWords = words;
    char text[1024];
    size_t tl = 0;
    do {
        while (words && (isLower(peek(s)) || isUpper(peek(s)))) {
            char c = next(s);
            int w = isLower(c) ? c - 'a' : (words = false, c - 'A');
            if (w >= s->nwords || tl + s->wlen[w] > sizeof text) { s->bad = true; return; }
            memcpy(text + tl, s->word[w], s->wlen[w]);
            tl += s->wlen[w];
        }
        if (nextIf(s, '0')) break;
        int n = natural(s);
        if (puny) nextIf(s, '_');
        if (n <= 0 || s->i + n > s->len || (hadWords && tl + n > sizeof text)) { s->bad = true; return; }
        if (hadWords) memcpy(text + tl, s->in + s->i, n), tl += n;
        if (!puny) addWords(s, s->in + s->i, n);
        s->i += n;
    } while (words);
    sub(s);
    if (!hadWords) { put(s, s->in + from, s->i - from); return; }
    if (!tl || isDigit(text[0])) { s->bad = true; return; }
    char num[16];
    put(s, num, snprintf(num, sizeof num, "%zu", tl));
    put(s, text, tl);
}

static void backref(RW *s, int idx, int rep) {
    if (idx < 0 || idx >= s->nsub || rep > 2048) { s->bad = true; return; }
    int k = s->map[idx];
    char b[16];
    for (int r = 0; r < (rep > 1 ? rep : 1); r++)
        put(s, b, k < 26 ? snprintf(b, sizeof b, "A%c", 'A' + k)
                  : k == 26 ? snprintf(b, sizeof b, "A_") : snprintf(b, sizeof b, "A%d_", k - 27));
}

static void substitutions(RW *s) {               // after 'A': demangleMultiSubstitutions
    for (int rep = -1; !s->bad;) {
        char c = next(s);
        if (isLower(c)) { backref(s, c - 'a', rep); rep = -1; continue; }
        if (isUpper(c)) { backref(s, c - 'A', rep); return; }
        if (c == '_') { backref(s, rep + 27, 1); return; }
        if (!isDigit(c)) { s->bad = true; return; }
        s->i--;
        rep = natural(s);
    }
}

static void symbolicRef(RW *s, unsigned char c) {
    const char *field = s->in + s->i + 1;
    int32_t rel;
    memcpy(&rel, field, 4);
    // context references are numbered, except opaque type descriptors (kind 4)
    if (c <= 0x02) {
        const char *d = field + rel;
        if (c == 0x02) d = *(const char *const *)d;
        if ((*(const uint32_t *)d & 0x1f) != 4) sub(s);
    }
    intptr_t nrel = (intptr_t)(field + rel) - (intptr_t)(s->out + s->o + 1);
    if (nrel != (int32_t)nrel) { s->bad = true; return; }
    int32_t r32 = (int32_t)nrel;
    put(s, &c, 1);
    put(s, &r32, 4);
    s->i += 5;
}

// Rewrites name into out: returns the length, 0 if nothing changed, -1 if it can't
// (*failAt = offset).
static long rewriteInto(const char *name, size_t len, char *out, size_t cap, size_t *failAt) {
    static RW zero;
    RW st = zero, *s = &st;
    s->in = name, s->len = len, s->out = out, s->cap = cap;
    while (s->i < len && !s->bad) {
        size_t from = s->i;
        unsigned char c = next(s);
        bool copy = true;
        switch (c) {
        case 0x01 ... 0x17:
            s->i--;
            if (s->i + 5 > len) { s->bad = true; break; }
            symbolicRef(s, c);
            copy = false;
            break;
        case 0x18 ... 0x1F: s->i += 8; break;
        case 0xFF: break;
        case '0' ... '9':
            s->i--;
            identifier_(s);
            copy = false;
            break;
        case 'A': substitutions(s), copy = false; break;
        case 'C': case 'O': case 'P': case 'V': case 'a': case 'G': sub(s); break;
        case 'S': {
            if (s->i + 4 <= len && !memcmp(name + s->i, "cMYc", 4)) {   // ScMYc: dropped
                s->i += 4, s->changed = true, copy = false;
                break;
            }
            char k = next(s);
            if (!k) { s->bad = true; break; }
            if (k == 'o' || k == 'C') break;
            if (k == 'g') { sub(s); break; }
            s->i--;
            int rep = natural(s);
            const char *e = nextIf(s, 'c') ? expansion(peek(s)) : NULL;
            if (!next(s)) { s->bad = true; break; }
            if (!e) break;
            for (int r = 0; r < (rep > 1 ? rep : 1); r++) put(s, e, strlen(e)), s->nnew += 2;
            s->changed = true, copy = false;
            break;
        }
        case 'Y':
            switch (next(s)) {
            case 'a': case 'b': s->changed = true, copy = false; break;   // async, @Sendable
            case 'c': case 'i': case 'k': break;
            case 'j': if (!next(s)) s->bad = true; break;
            default: s->bad = true;
            }
            break;
        case 'Q':
            switch (next(s)) {
            case 'a': case 'x': case 'X': case 'z': case 'Z': sub(s); break;
            case 'y': case 'Y': paramIndex(s), sub(s); break;
            case 'o': index_(s), sub(s); break;
            case 'O': case 'r': break;
            default: s->bad = true;
            }
            break;
        case 'B': {
            char k = next(s);
            if (k == 'f' || k == 'i' || k == 'v') index_(s);
            else if (!k) s->bad = true;
            break;
        }
        case 'X': {
            char k = next(s);
            if (k == 'M' || k == 'm' || k == 'S') { if (!next(s)) s->bad = true; }
            else if (k == 'Y') sub(s);
            else if (k == 'z' || !k) s->bad = true;
            break;
        }
        case 'M': {
            char k = next(s);
            if (k == 'X' || !k) s->bad = true;
            break;
        }
        case 'L':
            if (!nextIf(s, 'L') && !nextIf(s, 'l')) {
                char k = peek(s);
                if ((k >= 'a' && k <= 'j') || (k >= 'A' && k <= 'J')) s->i++;
                else index_(s);
            }
            break;
        case 'g': index_(s); break;
        case 'q': paramIndex(s); break;
        case 'r':
            while (!s->bad && !nextIf(s, 'l'))
                if (s->i >= len) s->bad = true;
                else if (!nextIf(s, 'z')) index_(s);
            break;
        case 'x': case 'y': case 't': case 'c': case '_': case 'p': case 'm': case 'z':
        case 'h': case 'n': case 'd': case 'K': case 'N': case 'u': case 'Z': case 'l':
        case 's': case 'E': case 'D':
            break;
        default: s->bad = true;
        }
        if (copy && !s->bad) put(s, name + from, s->i - from);
    }
    if (s->bad) { *failAt = s->i; return -1; }
    return s->changed ? (long)s->o : 0;
}

static const void *memoKeys[4096], *memoVals[4096];
static size_t memoLens[4096];
static int nmemo;

// Rewritten copy of name[0..len) or NULL if it has no Concurrency substitution / can't.
static const char *rewrite(const char *name, size_t len, size_t *outLen) {
    if (!needsRewrite(name, len)) return NULL;

    os_unfair_lock_lock(&lock);
    for (int i = 0; i < nmemo; i++)
        if (memoKeys[i] == name) {
            *outLen = memoLens[i];
            os_unfair_lock_unlock(&lock);
            return memoVals[i];
        }
    size_t cap = len * 16 + 256, failAt = 0;
    char *out = arenaAlloc((uintptr_t)name, cap);
    long n = out ? rewriteInto(name, len, out, cap, &failAt) : -1;
    if (out) arenaTrim(out, cap, n > 0 ? n : 0);
    if (n <= 0) out = NULL;
    if (nmemo < 4096) {
        memoKeys[nmemo] = name, memoVals[nmemo] = out, memoLens[nmemo] = n > 0 ? n : 0;
        nmemo++;
    }
    os_unfair_lock_unlock(&lock);
#if WAPORT_LOG
    if (n < 0) shimlog(@"type lookup %@: can't rewrite (at %zu)", printable(name, len), failAt);
#endif
    if (!out) return NULL;
    *outLen = n;
    return out;
}

// An indirect context-descriptor reference (0x02: int32 offset to a pointer) whose pointer
// is null names a type the target lacks (weak-null descriptor import, e.g. the iOS 15
// UIKit overlay's UIButton.Configuration). 14's demangler dereferences it and crashes, so
// such lookups return null (logged with the slot, which `tools/machotool.py` maps to the
// import).
static const void *nullIndirectRef(const char *name, size_t len) {
    for (size_t i = 0; i < len;) {
        unsigned char c = name[i];
        size_t r = symref(c);
        if (!r) { i++; continue; }
        if (c == 0x02 && i + 5 <= len) {
            int32_t rel;
            memcpy(&rel, name + i + 1, 4);
            const void *const *slot = (const void *const *)(name + i + 1 + rel);
            if (!*slot) return slot;
        }
        i += r;
    }
    return NULL;
}

static bool lacksType(const char *n, size_t len) {
    const void *slot = nullIndirectRef(n, len);
    if (!slot) return false;
#if WAPORT_LOG
    Dl_info di;
    if (dladdr(slot, &di) && di.dli_fname) {
        const char *img = strrchr(di.dli_fname, '/');
        shimlog(@"type lookup %@: missing type (null descriptor slot %s+0x%lx) -> null", printable(n, len),
                img ? img + 1 : di.dli_fname, (unsigned long)((uintptr_t)slot - (uintptr_t)di.dli_fbase));
    } else {
        shimlog(@"type lookup %@: missing type (null descriptor slot %p) -> null", printable(n, len), slot);
    }
#endif
    return true;
}

static void *core(const char *sym) {
    static void *h;
    if (!h) h = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOLOAD | RTLD_LAZY);
    return dlsym(h, sym);
}

typedef struct { const void *metadata; size_t state; } MetadataResponse;

#if WAPORT_LOG
static NSString *printable(const char *n, size_t len) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < len; i++) {
        unsigned char c = n[i];
        if (c >= 0x01 && c <= 0x17 && i + 4 < len) { [s appendFormat:@"<%02x>", c]; i += 4; }
        else if (c >= 0x18 && c <= 0x1F && i + 8 < len) { [s appendFormat:@"<%02x>", c]; i += 8; }
        else if (c < 0x20 || c > 0x7e) [s appendFormat:@"\\x%02x", c];
        else [s appendFormat:@"%c", c];
    }
    return s;
}
#define RETRYLOG(n, len, n2, l2, r, r2) \
    shimlog(@"type lookup %@ (%p) -> %@ -> %p", printable(n, len), r, printable(n2, l2), r2)
#define NULLLOG(n, len, r) \
    do { if (!(r)) shimlog(@"type lookup %@ -> null", printable(n, len)); } while (0)
#else
#define RETRYLOG(n, len, n2, l2, r, r2) ((void)0)
#define NULLLOG(n, len, r) ((void)0)
#endif

EXPORT const void *swift_getTypeByMangledNameInContext(const char *n, size_t len, const void *ctx,
                                                       const void *const *args) {
    static const void *(*real)(const char *, size_t, const void *, const void *const *);
    if (!real) real = core("swift_getTypeByMangledNameInContext");
    if (lacksType(n, len)) return NULL;
    const void *r = real(n, len, ctx, args);
    size_t l2;
    const char *n2;
    if ((n2 = rewrite(n, len, &l2))) {
        const void *r2 = real(n2, l2, ctx, args);
        RETRYLOG(n, len, n2, l2, r, r2);
        if (r2) r = r2;
    }
    NULLLOG(n, len, r);
    return r;
}

EXPORT MetadataResponse swift_getTypeByMangledNameInContextInMetadataState(size_t req, const char *n, size_t len,
                                                                           const void *ctx, const void *const *args) {
    static MetadataResponse (*real)(size_t, const char *, size_t, const void *, const void *const *);
    if (!real) real = core("swift_getTypeByMangledNameInContextInMetadataState");
    if (lacksType(n, len)) return (MetadataResponse){NULL, 0};
    MetadataResponse r = real(req, n, len, ctx, args);
    size_t l2;
    const char *n2;
    if ((n2 = rewrite(n, len, &l2))) {
        MetadataResponse r2 = real(req, n2, l2, ctx, args);
        RETRYLOG(n, len, n2, l2, r.metadata, r2.metadata);
        if (r2.metadata) r = r2;
    }
    NULLLOG(n, len, r.metadata);
    return r;
}

EXPORT const void *swift_getTypeByMangledNameInEnvironment(const char *n, size_t len, const void *env,
                                                           const void *const *args) {
    static const void *(*real)(const char *, size_t, const void *, const void *const *);
    if (!real) real = core("swift_getTypeByMangledNameInEnvironment");
    if (lacksType(n, len)) return NULL;
    const void *r = real(n, len, env, args);
    size_t l2;
    const char *n2;
    if ((n2 = rewrite(n, len, &l2))) {
        const void *r2 = real(n2, l2, env, args);
        RETRYLOG(n, len, n2, l2, r, r2);
        if (r2) r = r2;
    }
    NULLLOG(n, len, r);
    return r;
}

EXPORT MetadataResponse swift_getTypeByMangledNameInEnvironmentInMetadataState(size_t req, const char *n, size_t len,
                                                                               const void *env, const void *const *args) {
    static MetadataResponse (*real)(size_t, const char *, size_t, const void *, const void *const *);
    if (!real) real = core("swift_getTypeByMangledNameInEnvironmentInMetadataState");
    if (lacksType(n, len)) return (MetadataResponse){NULL, 0};
    MetadataResponse r = real(req, n, len, env, args);
    size_t l2;
    const char *n2;
    if ((n2 = rewrite(n, len, &l2))) {
        MetadataResponse r2 = real(req, n2, l2, env, args);
        RETRYLOG(n, len, n2, l2, r.metadata, r2.metadata);
        if (r2.metadata) r = r2;
    }
    NULLLOG(n, len, r.metadata);
    return r;
}

#if WAPORT_LOG
// launch self-test: can the target resolve the spelled-out names at all?
__attribute__((constructor)) static void selftest(void) {
    const void *(*real)(const char *, size_t, const void *, const void *const *) =
        core("swift_getTypeByMangledNameInContext");
    const char *names[] = {"Si", "ScP", "s12TaskPriorityV", "s12TaskPriorityVSg", "s4TaskVyyts5NeverOG",
                           "s9MainActorC"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        shimlog(@"selftest %s -> %p", names[i], real(names[i], strlen(names[i]), NULL, NULL));
    shimlog(@"selftest yyYbScMYcc raw %p, hooked %p, yyc %p", real("yyYbScMYcc", 10, NULL, NULL),
            swift_getTypeByMangledNameInContext("yyYbScMYcc", 10, NULL, NULL), real("yyc", 3, NULL, NULL));
    shimlog(@"selftest libswift_Concurrency loaded: %p", dlopen("@rpath/libswift_Concurrency.dylib", RTLD_NOLOAD));
    // back-reference renumbering: `sAC_p` (Error) must become `sAE_p`
    const char *br = "ScCys6ResultOyyts5Error_pGsAC_pG", *bs = "s19CheckedContinuationVys6ResultOyyts5Error_pGs5Error_pG";
    shimlog(@"selftest %s hooked %p, spelled %p", br, swift_getTypeByMangledNameInContext(br, strlen(br), NULL, NULL),
            real(bs, strlen(bs), NULL, NULL));
}
#endif
