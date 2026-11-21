/* Hand-written config.h for building libmp3lame 3.100 with SwiftPM / Xcode
   on Apple platforms (arm64/x86_64) and Linux. */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

/* Always build LAME like its own release builds: SwiftPM/Xcode define DEBUG=1 in debug configurations,
   which would turn on LAME's internal debug printing, and asserts are compiled out (none has side effects). */
#undef DEBUG
#ifndef NDEBUG
#define NDEBUG 1
#endif

#define STDC_HEADERS 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define HAVE_LIMITS_H 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1

#include <stdint.h>
#include <inttypes.h>

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;
#define HAVE_IEEE754_FLOAT32_T 1
#define HAVE_IEEE754_FLOAT64_T 1
#define HAVE_IEEE854_FLOAT80_T 1

/* faster, table based log() used by the psycho-acoustic model */
#define USE_FAST_LOG 1

#define PACKAGE "lame"
#define PACKAGE_NAME "lame"
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"

#endif /* LAME_CONFIG_H */
