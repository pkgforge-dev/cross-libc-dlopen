/* Functional test for the generated shim, run on glibc 2.31 where these
   symbols genuinely do not exist. Each check states what correct means. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <stdlib.h>

extern size_t strlcpy(char *, const char *, size_t);
extern size_t strlcat(char *, const char *, size_t);
extern uint32_t arc4random(void);
extern uint32_t arc4random_uniform(uint32_t);
extern void arc4random_buf(void *, size_t);
extern int _dl_find_object(void *, void *);
extern unsigned stdc_leading_zeros_ui(unsigned);
extern unsigned stdc_trailing_zeros_ui(unsigned);
extern unsigned stdc_count_ones_ui(unsigned);
extern unsigned stdc_bit_width_ui(unsigned);
extern unsigned stdc_first_leading_one_ui(unsigned);
extern unsigned stdc_count_zeros_uc(unsigned char);
extern unsigned stdc_leading_ones_uc(unsigned char);
extern unsigned stdc_bit_floor_ui(unsigned);
extern unsigned stdc_bit_ceil_ui(unsigned);
extern _Bool stdc_has_single_bit_ui(unsigned);
extern char __libc_single_threaded;
extern const char *sigabbrev_np(int);

/* The version argument __xstat takes belongs to the ABI, and glibc 2.31
   exports no usable macro for it: <sys/stat.h> defines no _STAT_VER at all on
   x86-64, and defines it as _STAT_VER_KERNEL on aarch64, which is itself
   undefined, so a program naming it does not compile on either. Measured with
   gcc -E -dM for both targets on debian:bullseye-slim.

   The value is 1 on x86-64, which every passing run of E16 has used, and 0
   where the kernel's stat layout is the only one there has ever been.
   Measured under qemu-user on aarch64: __xstat(0) returns 0 and fills the
   struct, __xstat(1) returns -1 with EINVAL. A hardcoded 1 is what made E16
   report FAIL on the ARM runner while every other check in this file passed. */
#if defined(__x86_64__) || defined(__i386__)
#  define CLD_STAT_VER 1
#else
#  define CLD_STAT_VER 0
#endif

static int fails = 0;
#define CK(what, cond) do { if (cond) printf("  ok   %s\n", what); \
        else { printf("  FAIL %s\n", what); fails++; } } while (0)

static int atexit_ran = 0;
static void bye(void) { atexit_ran = 1; }

int main(void) {
    char b[8];

    /* strlcpy: returns strlen(src), always NUL-terminates, never overflows */
    memset(b, 'X', sizeof b);
    CK("strlcpy short",  strlcpy(b, "abc", sizeof b) == 3 && !strcmp(b, "abc"));
    memset(b, 'X', sizeof b);
    CK("strlcpy trunc",  strlcpy(b, "0123456789", sizeof b) == 10
                          && !strcmp(b, "0123456") && b[7] == '\0');
    CK("strlcpy n=0",    (strcpy(b, "keep"), strlcpy(b, "zzz", 0) == 3
                          && !strcmp(b, "keep")));

    /* strlcat: returns the length it TRIED to make */
    strcpy(b, "ab");
    CK("strlcat fits",   strlcat(b, "cd", sizeof b) == 4 && !strcmp(b, "abcd"));
    strcpy(b, "abcde");
    CK("strlcat trunc",  strlcat(b, "XYZ", sizeof b) == 8 && !strcmp(b, "abcdeXY"));

    /* arc4random_uniform must be in range and must not always return 0 */
    int seen[4] = {0,0,0,0}, distinct = 0;
    for (int i = 0; i < 4000; i++) {
        uint32_t v = arc4random_uniform(4);
        if (v > 3) { printf("  FAIL arc4random_uniform out of range\n"); fails++; break; }
        seen[v] = 1;
    }
    for (int i = 0; i < 4; i++) distinct += seen[i];
    CK("arc4random_uniform covers range", distinct == 4);
    CK("arc4random_uniform(0)==0", arc4random_uniform(0) == 0);
    CK("arc4random_uniform(1)==0", arc4random_uniform(1) == 0);

    unsigned char z[32]; memset(z, 0, sizeof z);
    arc4random_buf(z, sizeof z);
    int nz = 0; for (size_t i = 0; i < sizeof z; i++) if (z[i]) nz++;
    CK("arc4random_buf fills",  nz > 16);
    CK("arc4random varies",     arc4random() != arc4random());

    /* stat: the shim routes through __xstat. Compare against the real thing. */
    struct stat s1, s2;
    CK("stat /etc/hostname",  stat("/etc/hostname", &s1) == 0);
    CK("stat matches __xstat",
       (__xstat(CLD_STAT_VER, "/etc/hostname", &s2) == 0) && s1.st_ino == s2.st_ino
        && s1.st_size == s2.st_size && s1.st_mode == s2.st_mode);
    CK("stat ENOENT",   stat("/nonexistent-abcdef", &s1) == -1);
    CK("fstat stdin",   fstat(0, &s1) == 0);
    CK("lstat /etc",    lstat("/etc", &s1) == 0 && S_ISDIR(s1.st_mode));

    /* C23 bit utilities, against known-good values */
    CK("clz(1)==31",             stdc_leading_zeros_ui(1) == 31);
    CK("clz(0)==32",             stdc_leading_zeros_ui(0) == 32);
    CK("ctz(8)==3",              stdc_trailing_zeros_ui(8) == 3);
    CK("ctz(0)==32",             stdc_trailing_zeros_ui(0) == 32);
    CK("popcount(0xF0F0)==8",    stdc_count_ones_ui(0xF0F0) == 8);
    CK("count_zeros_uc(0)==8",   stdc_count_zeros_uc(0) == 8);
    CK("leading_ones_uc(0xF0)==4", stdc_leading_ones_uc(0xF0) == 4);
    CK("leading_ones_uc(0xFF)==8", stdc_leading_ones_uc(0xFF) == 8);
    CK("bit_width(0)==0",        stdc_bit_width_ui(0) == 0);
    CK("bit_width(1)==1",        stdc_bit_width_ui(1) == 1);
    CK("bit_width(255)==8",      stdc_bit_width_ui(255) == 8);
    CK("first_leading_one(0)==0",stdc_first_leading_one_ui(0) == 0);
    CK("first_leading_one(1)==32",stdc_first_leading_one_ui(1) == 32);
    CK("bit_floor(100)==64",     stdc_bit_floor_ui(100) == 64);
    CK("bit_floor(0)==0",        stdc_bit_floor_ui(0) == 0);
    CK("bit_ceil(100)==128",     stdc_bit_ceil_ui(100) == 128);
    CK("bit_ceil(0)==1",         stdc_bit_ceil_ui(0) == 1);
    CK("bit_ceil(1)==1",         stdc_bit_ceil_ui(1) == 1);
    CK("bit_ceil(64)==64",       stdc_bit_ceil_ui(64) == 64);
    CK("has_single_bit(64)",     stdc_has_single_bit_ui(64));
    CK("!has_single_bit(65)",    !stdc_has_single_bit_ui(65));
    CK("!has_single_bit(0)",     !stdc_has_single_bit_ui(0));

    /* documented fallbacks */
    CK("_dl_find_object==-1",    _dl_find_object((void*)main, NULL) == -1);
    CK("__libc_single_threaded==0", __libc_single_threaded == 0);
    CK("sigabbrev_np(SIGKILL)",  sigabbrev_np(9) && !strcmp(sigabbrev_np(9), "KILL"));
    CK("sigabbrev_np(0)==NULL",  sigabbrev_np(0) == NULL);

    CK("atexit registers",       atexit(bye) == 0);

    printf("\n%s (%d failures)\n", fails ? "SHIM TEST FAILED" : "SHIM TEST PASSED", fails);
    return fails != 0;
}
