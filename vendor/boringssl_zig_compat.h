#ifndef KOKO_BORINGSSL_ZIG_COMPAT_H
#define KOKO_BORINGSSL_ZIG_COMPAT_H

#include <openssl/base.h>

// Zig 0.16 translate-c does not accept the _Pragma expressions emitted by
// BoringSSL's typed stack macros. They only suppress C compiler warnings and
// are not needed for generated Zig bindings.
#undef OPENSSL_GNUC_CLANG_PRAGMA
#undef OPENSSL_CLANG_PRAGMA
#define OPENSSL_GNUC_CLANG_PRAGMA(arg)
#define OPENSSL_CLANG_PRAGMA(arg)

#include <openssl/ssl.h>

#endif
