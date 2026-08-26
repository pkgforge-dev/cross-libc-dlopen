/* Tier-0 tests for the ELF rewriting in src/cross-libc-dlopen.c.
 *
 * Covers T0.4 (round-trip), T0.5 (idempotence), T0.7 (tail-merge
 * guard) and T0.8 (malformed-input fuzz).
 *
 * It #includes the implementation rather than reimplementing the predicates,
 * because a Tier-0 test that models the C instead of running it can pass while
 * the shipped code is wrong. Building it as a program is safe: every
 * constructor in there is gated on cross_libc_dlopen_mode(), which is false
 * unless CROSS_LIBC_DLOPEN=1 is set, and this test never sets it.
 *
 *   cc -O2 -o elf-selftest tests/elf-selftest.c -ldl
 *   ./elf-selftest <some.so>
 */
#include "../src/cross-libc-dlopen.c"

#include <assert.h>

static int fails;

#define CK(what, cond) do { \
	if (cond) printf("  ok   %s\n", what); \
	else { printf("  FAIL %s\n", what); fails++; } \
} while (0)

/* ---------------------------------------------------------------- T0.4/T0.5 */

static int count_version_tags(const struct cld_elf *e) {
	int n = 0;
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++)
		if (e->dyn[i].d_tag == DT_VERSYM || e->dyn[i].d_tag == DT_VERNEED ||
		    e->dyn[i].d_tag == DT_VERDEF || e->dyn[i].d_tag == DT_VERDEFNUM)
			n++;
	return n;
}

static void test_strip(const char *path) {
	struct cld_elf a, b;

	if (!cld_parse_elf(&a, path)) {
		printf("  SKIP T0.4/T0.5 - cannot parse %s\n", path);
		return;
	}
	size_t orig_size = a.size;
	int before = count_version_tags(&a);

	cld_strip_versions(&a);
	CK("T0.4 every version tag goes together", count_version_tags(&a) == 0);
	CK("T0.4 size unchanged by stripping", a.size == orig_size);

	/* The stripped image must still be parseable, because a verdef left without its
	 * versym is what segfaults ld.so, so "it still parses" is the point. */
	char tmp[] = "/tmp/cld-selftest-XXXXXX";
	int fd = mkstemp(tmp);
	if (fd >= 0) {
		ssize_t w = write(fd, a.map, a.size);
		close(fd);
		CK("T0.4 stripped image writes out", w == (ssize_t)a.size);
		CK("T0.4 stripped image re-parses", cld_parse_elf(&b, tmp) != 0);
		if (b.map) {
			CK("T0.4 no version tags survive the round trip",
			   count_version_tags(&b) == 0);

			/* T0.5: stripping again changes nothing. */
			size_t n = b.size;
			char *copy = malloc(n);
			memcpy(copy, b.map, n);
			cld_strip_versions(&b);
			CK("T0.5 second strip is byte-identical", memcmp(copy, b.map, n) == 0);
			free(copy);
			cld_free_elf(&b);
		}
		unlink(tmp);
	}

	/* The content-derived name must be stable for the same input (T0.5). */
	unsigned h1 = cld_content_hash(path, orig_size);
	unsigned h2 = cld_content_hash(path, orig_size);
	CK("T0.5 content-hash name is stable", h1 == h2);
	CK("T0.4 file had version tags to begin with (test is meaningful)", before > 0);

	cld_free_elf(&a);
}

/* ------------------------------------------------------------------- T0.7 */
/*
 * The guard must REFUSE an in-place .dynstr write whose range another
 * reference falls inside. Rather than hope a real library happens to contain
 * such a case, build one: pick a real undefined symbol, then ask the guard
 * about a range that provably contains a second live reference.
 */
static void test_tail_merge_guard(const char *path) {
	struct cld_elf e;
	if (!cld_parse_elf(&e, path) || !e.dynsym || !e.strtab) {
		printf("  SKIP T0.7 - no usable .dynsym in %s\n", path);
		if (e.map) cld_free_elf(&e);
		return;
	}

	CK("T0.7 dynsym located and bounded", e.dynsym_num > 0 &&
	   e.dynsym_num < e.size / sizeof(ElfW(Sym)));

	/* Find two distinct symbol-name offsets. */
	size_t off_a = 0, off_b = 0;
	for (size_t i = 0; i < e.dynsym_num; i++) {
		size_t o = (size_t)e.dynsym[i].st_name;
		if (!o || !cld_valid_cstr(&e, o))
			continue;
		if (!off_a) { off_a = o; continue; }
		if (o != off_a) { off_b = o; break; }
	}

	if (!off_a || !off_b) {
		printf("  SKIP T0.7 - fewer than two named dynamic symbols\n");
		cld_free_elf(&e);
		return;
	}

	size_t lo = off_a < off_b ? off_a : off_b;
	size_t hi = off_a < off_b ? off_b : off_a;

	/* A range spanning the OTHER symbol's offset must be refused... */
	CK("T0.7 guard REFUSES a range containing another live reference",
	   cld_dynstr_range_occupied(&e, lo, hi + 1, lo) == 1);

	/* ...while a range covering only the exempt string's own bytes is fine,
	 * provided nothing else starts inside it. Scan for one that qualifies. */
	int found_clear = 0;
	for (size_t i = 0; i < e.dynsym_num && !found_clear; i++) {
		size_t o = (size_t)e.dynsym[i].st_name;
		if (!o || !cld_valid_cstr(&e, o))
			continue;
		size_t len = strlen(e.strtab + o);
		if (len < 2)
			continue;
		if (!cld_dynstr_range_occupied(&e, o + 1, o + len + 1, o))
			found_clear = 1;
	}
	CK("T0.7 guard ALLOWS a range nothing else references", found_clear);

	/* The rename entry we actually ship must be a pure suffix identity: no
	 * .dynstr write is even attempted, which is what makes it total. */
	CK("T0.7 shipped rename is a suffix identity (no write needed)",
	   strcmp(cld_renames[0].from + (strlen(cld_renames[0].from) -
	                                 strlen(cld_renames[0].to)),
	          cld_renames[0].to) == 0);

	cld_free_elf(&e);
}

/* ------------------------------------------------------------------- T0.8 */
/*
 * Truncated and bit-flipped ELFs must be refused cleanly: no crash, no read
 * past the buffer. The parser is the only code that ever sees a host file we
 * did not create, so it is the whole attack surface.
 */
static void test_fuzz(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) { printf("  SKIP T0.8 - cannot read %s\n", path); return; }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (n <= 0 || n > (16 << 20)) { fclose(f); printf("  SKIP T0.8 - bad size\n"); return; }
	unsigned char *buf = malloc((size_t)n);
	if (fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return; }
	fclose(f);

	/* mkstemp REWRITES its template in place, so it has to be reset before
	 * every call. Reusing a spent template silently fails and makes the whole
	 * loop a no-op, which is exactly how this test first "passed" nothing. */
	char tmp[64];
#define FRESH_TMP() strcpy(tmp, "/tmp/cld-fuzz-XXXXXX")
	int survived = 0, attempts = 0;

	/* Truncations, including every length near a header boundary. */
	for (long cut = 1; cut < n; cut = cut < 4096 ? cut + 17 : cut * 2) {
		FRESH_TMP();
		int fd = mkstemp(tmp);
		if (fd < 0) break;
		ssize_t w = write(fd, buf, (size_t)cut);
		close(fd);
		if (w == cut) {
			struct cld_elf e;
			attempts++;
			if (cld_parse_elf(&e, tmp)) {
				/* Parsing a truncation is allowed to succeed, but everything
				 * it reports must stay inside the file it actually read. */
				if (e.dynsym_num <= e.size / sizeof(ElfW(Sym)) &&
				    (!e.strtab || (size_t)(e.strtab - e.map) + e.strsz <= e.size)) {
					survived++;
					cld_apply_renames(&e, 1);   /* dry run: must not crash */
				}
				cld_free_elf(&e);
			} else {
				survived++;                     /* a clean refusal is correct */
			}
		}
		unlink(tmp);
	}
	CK("T0.8 every truncation refused or bounded", attempts > 0 && survived == attempts);

	/* Bit flips in the first 8 KiB, where every header lives. */
	attempts = survived = 0;
	for (long pos = 0; pos < (n < 8192 ? n : 8192); pos += 61) {
		unsigned char save = buf[pos];
		buf[pos] ^= 0xA5;
		FRESH_TMP();
		int fd = mkstemp(tmp);
		if (fd >= 0) {
			ssize_t w = write(fd, buf, (size_t)n);
			close(fd);
			if (w == n) {
				struct cld_elf e;
				attempts++;
				if (cld_parse_elf(&e, tmp)) {
					if (e.dynsym_num <= e.size / sizeof(ElfW(Sym))) {
						cld_apply_renames(&e, 1);
						cld_strip_versions(&e);
						survived++;
					} else {
						printf("    [fuzz] flip@%ld: dynsym_num=%zu exceeds "
						       "file (size=%zu)\n", pos, e.dynsym_num, e.size);
					}
					cld_free_elf(&e);
				} else {
					survived++;
				}
			}
			unlink(tmp);
		}
		buf[pos] = save;
	}
	CK("T0.8 every bit flip refused or bounded", attempts > 0 && survived == attempts);
	free(buf);
}

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "/lib/x86_64-linux-gnu/libz.so.1";

	printf("elf-selftest on %s\n", path);
	test_strip(path);
	test_tail_merge_guard(path);
	test_fuzz(path);

	printf("\n%s (%d failures)\n",
	       fails ? "ELF SELFTEST FAILED" : "ELF SELFTEST PASSED", fails);
	return fails != 0;
}
