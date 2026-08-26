/* runtime-select, Design R: choose the libc runtime at exec time.
 *
 * Design R. The only strategy that survives symbols invented after we
 * ship (4.5, E12): if the host's glibc is newer than the one we bundle and a
 * complete matched set is present, re-exec the app under the HOST's runtime,
 * so a future symbol resolves because we are using the future libc itself.
 *
 * The three things that make this correct rather than merely plausible:
 *
 *  1. E11: a MIXED runtime set segfaults instantly. So the set is verified
 *     whole, statically, before anything is exec'd. The check is not "do the
 *     files exist" but "does each member's VERNEED on its peers fall inside
 *     what those peers actually define", the same predicate ld.so applies,
 *     evaluated ahead of time. That is exactly the E8 failure condition.
 *
 *  2. T4.2: bundled libraries must still win for everything that is not
 *     libc. A flat "--library-path $HOST_LIBDIR:$APPDIR/lib" (5.0's sketch)
 *     would hand the host libstdc++, libX11 and every other soname the win
 *     too. Instead a SYMLINK FARM under $XDG_RUNTIME_DIR holds the runtime
 *     set and nothing else, and goes ahead of $APPDIR/lib:
 *
 *         --library-path  $FARM : $APPDIR/lib : $HOST_LIBDIRS
 *                         ^^^^^   ^^^^^^^^^^^   ^^^^^^^^^^^^^
 *                         libc    everything    fallback for
 *                         only    bundled       what we lack
 *
 *     Symlinks, so T4.3 still holds: no host file is touched and every write
 *     lands under XDG_RUNTIME_DIR.
 *
 *  3. The static check is a prediction, so it is also verified empirically:
 *     --self-test execs a trivial probe under the candidate runtime first. A
 *     set that would segfault (E11) is caught before the real app runs.
 *
 * Usage:
 *   runtime-select --probe            decide and explain, exec nothing
 *   runtime-select -- CMD [ARGS...]   decide, then exec CMD under the choice
 *   runtime-select --host-dir DIR     treat DIR as the host runtime
 *   runtime-select --no-self-test     skip the empirical verification
 *
 * Environment:
 *   CROSS_LIBC_DLOPEN_RUNTIME=host|bundled|auto   force the decision (default auto)
 *   CROSS_LIBC_DLOPEN_DEBUG=1                 log the decision and its reason
 *   APPDIR                               the AppDir; --appdir overrides
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dirent.h>
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <link.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* The one /etc/ld.so.conf walk, shared with src/gl-fwd.c. */
#include "ld-conf.h"
#include "cld-env.h"

#define RS_MAX_VERSIONS 512
#define RS_MAX_PATH     PATH_MAX

#if defined(__x86_64__)
#  define RS_LDSO   "ld-linux-x86-64.so.2"
#  define RS_TRIPLET "x86_64-linux-gnu"
#elif defined(__aarch64__)
#  define RS_LDSO   "ld-linux-aarch64.so.1"
#  define RS_TRIPLET "aarch64-linux-gnu"
#elif defined(__i386__)
#  define RS_LDSO   "ld-linux.so.2"
#  define RS_TRIPLET "i386-linux-gnu"
#else
#  define RS_LDSO   "ld-linux.so.2"
#  define RS_TRIPLET "unknown"
#endif

/* The set that must be switched WHOLE (E11). libc and ld.so are mandatory;
 * the rest are only required when the bundle itself ships them, and a host that
 * dropped libanl.so.1 is not "incomplete" if we never had it either. */
static const char *rs_runtime_set[] = {
	RS_LDSO, "libc.so.6", "libm.so.6",
	"libdl.so.2", "libpthread.so.0", "librt.so.1", "libutil.so.1", "libanl.so.1",
	NULL
};

static const char *rs_host_libdirs[] = {
	"/lib/" RS_TRIPLET, "/usr/lib/" RS_TRIPLET,
	"/lib64", "/usr/lib64", "/lib", "/usr/lib",
	NULL
};

static int rs_debug;

static void rs_log(const char *fmt, ...) {
	if (!rs_debug)
		return;
	va_list ap;
	va_start(ap, fmt);
	fputs(" [runtime-select] >> ", stderr);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

/* ------------------------------------------------------------------ ELF */
/* Deliberately self-contained: a launcher that had to link against the thing
 * it is choosing a runtime for would be its own bootstrap problem. */

struct rs_elf {
	char *map;
	size_t size;
	ElfW(Dyn) *dyn;
	size_t dyn_num;
	const char *strtab;
	size_t strsz;
	const ElfW(Phdr) *phdr;
	int phnum;
};

static void rs_close(struct rs_elf *e) {
	free(e->map);
	memset(e, 0, sizeof(*e));
}

static size_t rs_v2o(const struct rs_elf *e, ElfW(Addr) v) {
	for (int i = 0; i < e->phnum; i++) {
		if (e->phdr[i].p_type != PT_LOAD)
			continue;
		if (v >= e->phdr[i].p_vaddr && v < e->phdr[i].p_vaddr + e->phdr[i].p_filesz) {
			size_t off = (size_t)(e->phdr[i].p_offset + (v - e->phdr[i].p_vaddr));
			return off < e->size ? off : (size_t)-1;
		}
	}
	return (size_t)-1;
}

static int rs_open(struct rs_elf *e, const char *path) {
	memset(e, 0, sizeof(*e));
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	struct stat st;
	if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(ElfW(Ehdr)) ||
	    st.st_size > ((off_t)1 << 30)) {
		close(fd);
		return 0;
	}
	e->size = (size_t)st.st_size;
	if (!(e->map = malloc(e->size))) {
		close(fd);
		return 0;
	}
	size_t done = 0;
	while (done < e->size) {
		ssize_t n = read(fd, e->map + done, e->size - done);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			rs_close(e);
			return 0;
		}
		done += (size_t)n;
	}
	close(fd);

	const ElfW(Ehdr) *eh = (const ElfW(Ehdr) *)e->map;
	if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
	    eh->e_ident[EI_CLASS] != (sizeof(void *) == 8 ? ELFCLASS64 : ELFCLASS32) ||
	    eh->e_ident[EI_DATA] != ELFDATA2LSB ||
	    !eh->e_phnum || eh->e_phnum > 4096 ||
	    eh->e_phoff + (size_t)eh->e_phnum * sizeof(ElfW(Phdr)) > e->size) {
		rs_close(e);
		return 0;
	}
	e->phdr = (const ElfW(Phdr) *)(e->map + eh->e_phoff);
	e->phnum = (int)eh->e_phnum;

	for (int i = 0; i < e->phnum; i++) {
		if (e->phdr[i].p_type != PT_DYNAMIC)
			continue;
		if (e->phdr[i].p_offset >= e->size ||
		    e->phdr[i].p_filesz > e->size - e->phdr[i].p_offset)
			break;
		e->dyn = (ElfW(Dyn) *)(e->map + e->phdr[i].p_offset);
		e->dyn_num = e->phdr[i].p_filesz / sizeof(ElfW(Dyn));
		break;
	}
	if (!e->dyn) {
		rs_close(e);
		return 0;
	}

	ElfW(Addr) strv = 0;
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		if (e->dyn[i].d_tag == DT_STRTAB)
			strv = (ElfW(Addr))e->dyn[i].d_un.d_ptr;
		else if (e->dyn[i].d_tag == DT_STRSZ)
			e->strsz = (size_t)e->dyn[i].d_un.d_val;
	}
	if (strv) {
		size_t o = rs_v2o(e, strv);
		if (o != (size_t)-1 && o + e->strsz <= e->size)
			e->strtab = e->map + o;
	}
	if (!e->strtab) {
		rs_close(e);
		return 0;
	}
	return 1;
}

static int rs_dtag(const struct rs_elf *e, ElfW(Sxword) tag, ElfW(Addr) *out) {
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++)
		if (e->dyn[i].d_tag == tag) {
			*out = (ElfW(Addr))e->dyn[i].d_un.d_ptr;
			return 1;
		}
	return 0;
}

static int rs_str_ok(const struct rs_elf *e, size_t off) {
	return off < e->strsz && memchr(e->strtab + off, '\0', e->strsz - off) != NULL;
}

/* A set of version names, as a fixed array. glibc defines ~50. */
struct rs_vers {
	char *v[RS_MAX_VERSIONS];
	size_t n;
};

static void rs_vers_free(struct rs_vers *s) {
	for (size_t i = 0; i < s->n; i++)
		free(s->v[i]);
	s->n = 0;
}

static void rs_vers_add(struct rs_vers *s, const char *name) {
	for (size_t i = 0; i < s->n; i++)
		if (!strcmp(s->v[i], name))
			return;
	if (s->n < RS_MAX_VERSIONS)
		s->v[s->n++] = strdup(name);
}

static int rs_vers_has(const struct rs_vers *s, const char *name) {
	for (size_t i = 0; i < s->n; i++)
		if (!strcmp(s->v[i], name))
			return 1;
	return 0;
}

/* Versions this file DEFINES (DT_VERDEF). */
static int rs_verdef(const char *path, struct rs_vers *out) {
	struct rs_elf e;
	if (!rs_open(&e, path))
		return 0;
	ElfW(Addr) v = 0;
	if (!rs_dtag(&e, DT_VERDEF, &v)) {
		rs_close(&e);
		return 0;
	}
	size_t base = rs_v2o(&e, v);
	if (base == (size_t)-1) {
		rs_close(&e);
		return 0;
	}
	size_t pos = 0;
	for (size_t g = 0; g < 4096; g++) {
		if (base + pos + sizeof(ElfW(Verdef)) > e.size)
			break;
		const ElfW(Verdef) *vd = (const ElfW(Verdef) *)(e.map + base + pos);
		if (vd->vd_version != 1)
			break;
		/* VER_FLG_BASE names the file itself, not a version */
		if (!(vd->vd_flags & VER_FLG_BASE) && vd->vd_aux) {
			const ElfW(Verdaux) *a = (const ElfW(Verdaux) *)((const char *)vd + vd->vd_aux);
			if (rs_str_ok(&e, a->vda_name))
				rs_vers_add(out, e.strtab + a->vda_name);
		}
		if (!vd->vd_next)
			break;
		pos += vd->vd_next;
	}
	rs_close(&e);
	return 1;
}

/* Versions this file REQUIRES from `soname` (DT_VERNEED). */
static int rs_verneed_from(const char *path, const char *soname, struct rs_vers *out) {
	struct rs_elf e;
	if (!rs_open(&e, path))
		return 0;
	ElfW(Addr) v = 0;
	if (!rs_dtag(&e, DT_VERNEED, &v)) {
		rs_close(&e);
		return 1;                        /* nothing required is a valid answer */
	}
	size_t base = rs_v2o(&e, v);
	if (base == (size_t)-1) {
		rs_close(&e);
		return 0;
	}
	size_t pos = 0;
	for (size_t g = 0; g < 4096; g++) {
		if (base + pos + sizeof(ElfW(Verneed)) > e.size)
			break;
		const ElfW(Verneed) *vn = (const ElfW(Verneed) *)(e.map + base + pos);
		if (vn->vn_version != 1)
			break;
		int match = rs_str_ok(&e, vn->vn_file) &&
		            !strcmp(e.strtab + vn->vn_file, soname);
		size_t apos = pos + vn->vn_aux;
		for (size_t ag = 0; ag < 4096; ag++) {
			if (base + apos + sizeof(ElfW(Vernaux)) > e.size)
				break;
			const ElfW(Vernaux) *a = (const ElfW(Vernaux) *)(e.map + base + apos);
			if (match && rs_str_ok(&e, a->vna_name))
				rs_vers_add(out, e.strtab + a->vna_name);
			if (!a->vna_next)
				break;
			apos += a->vna_next;
		}
		if (!vn->vn_next)
			break;
		pos += vn->vn_next;
	}
	rs_close(&e);
	return 1;
}

/* ------------------------------------------------------- symbol tables */
/*
 * The VERNEED check below catches E8's direction, a NEW object needing a
 * version an OLD peer does not define. It provably cannot catch E11's
 * direction, because glibc never retires a version name: an OLD libdl.so.2
 * asks libc only for GLIBC_2.2.5, and every later glibc still defines that.
 * Version names alone say the mixed set is fine. It segfaults.
 *
 * What actually distinguishes it is the GLIBC_PRIVATE symbol surface, which
 * is not stable at all. Measured, glibc 2.31 -> 2.41:
 *
 *   old libdl.so.2       imports _dl_sym, _dl_addr, _dl_catch_error,
 *                        _dl_vsym, __libc_dlopen_mode: 2.41 exports NONE
 *   old libpthread.so.0  imports __libc_pthread_init, __libc_dlopen_mode,
 *                        _dl_make_stack_executable, ...: 13 gone
 *
 * So the real completeness test is a symbol test: every STRONG undefined
 * symbol of every member must be defined by the libc and ld.so it will be
 * paired with. That is what makes the E11 refusal static rather than a
 * hope that the self-test crashes in a detectable way.
 */
#define RS_SYMSET_BUCKETS 8192

struct rs_symset {
	char *names[RS_SYMSET_BUCKETS];
	size_t n;
};

static unsigned rs_hash(const char *s) {
	unsigned h = 2166136261u;
	while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
	return h;
}

static void rs_symset_free(struct rs_symset *s) {
	for (size_t i = 0; i < RS_SYMSET_BUCKETS; i++) {
		free(s->names[i]);
		s->names[i] = NULL;
	}
	s->n = 0;
}

static void rs_symset_add(struct rs_symset *s, const char *name) {
	if (s->n >= RS_SYMSET_BUCKETS / 2)
		return;                          /* full; callers treat this as "unknown" */
	unsigned i = rs_hash(name) % RS_SYMSET_BUCKETS;
	while (s->names[i]) {
		if (!strcmp(s->names[i], name))
			return;
		i = (i + 1) % RS_SYMSET_BUCKETS;
	}
	s->names[i] = strdup(name);
	if (s->names[i])
		s->n++;
}

static int rs_symset_has(const struct rs_symset *s, const char *name) {
	unsigned i = rs_hash(name) % RS_SYMSET_BUCKETS;
	unsigned guard = 0;
	while (s->names[i] && guard++ < RS_SYMSET_BUCKETS) {
		if (!strcmp(s->names[i], name))
			return 1;
		i = (i + 1) % RS_SYMSET_BUCKETS;
	}
	return 0;
}

/* Locate .dynsym. DT_HASH's nchain is the exact count; DT_GNU_HASH needs the
 * chain walk. Same problem, and same solution, as in cross-libc-dlopen.c. */
static int rs_dynsym(const struct rs_elf *e, size_t *off, size_t *count) {
	ElfW(Addr) symv = 0, hashv = 0, gnuv = 0;
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		if (e->dyn[i].d_tag == DT_SYMTAB)        symv  = e->dyn[i].d_un.d_ptr;
		else if (e->dyn[i].d_tag == DT_HASH)     hashv = e->dyn[i].d_un.d_ptr;
		else if (e->dyn[i].d_tag == DT_GNU_HASH) gnuv  = e->dyn[i].d_un.d_ptr;
	}
	if (!symv)
		return 0;
	size_t so = rs_v2o(e, symv);
	if (so == (size_t)-1)
		return 0;

	size_t n = 0;
	if (hashv) {
		size_t ho = rs_v2o(e, hashv);
		if (ho != (size_t)-1 && ho + 8 <= e->size) {
			uint32_t nchain;
			memcpy(&nchain, e->map + ho + 4, 4);
			n = nchain;
		}
	}
	if (!n && gnuv) {
		size_t go = rs_v2o(e, gnuv);
		if (go != (size_t)-1 && go + 16 <= e->size) {
			uint32_t hdr[4];
			memcpy(hdr, e->map + go, 16);
			uint32_t nbucket = hdr[0], symoffset = hdr[1], bloom = hdr[2];
			if (nbucket && nbucket < (1u << 24) && bloom < (1u << 24)) {
				size_t bo = go + 16 + (size_t)bloom * sizeof(ElfW(Addr));
				if (bo + (size_t)nbucket * 4 <= e->size) {
					uint32_t last = symoffset;
					for (uint32_t i = 0; i < nbucket; i++) {
						uint32_t b;
						memcpy(&b, e->map + bo + (size_t)i * 4, 4);
						if (b > last) last = b;
					}
					size_t co = bo + (size_t)nbucket * 4;
					uint32_t idx = last >= symoffset ? last - symoffset : 0;
					while (co + ((size_t)idx + 1) * 4 <= e->size) {
						uint32_t h;
						memcpy(&h, e->map + co + (size_t)idx * 4, 4);
						if (h & 1) break;
						idx++;
					}
					n = (size_t)symoffset + idx + 1;
				}
			}
		}
	}
	if (!n || n > (e->size - so) / sizeof(ElfW(Sym)))
		return 0;
	*off = so;
	*count = n;
	return 1;
}

/* Add every DEFINED symbol of `path` to `set`. */
static void rs_collect_exports(const char *path, struct rs_symset *set) {
	struct rs_elf e;
	size_t so, n;
	if (!rs_open(&e, path))
		return;
	if (rs_dynsym(&e, &so, &n)) {
		for (size_t i = 0; i < n; i++) {
			const ElfW(Sym) *s = (const ElfW(Sym) *)(e.map + so + i * sizeof(ElfW(Sym)));
			if (s->st_shndx == SHN_UNDEF || !s->st_name)
				continue;
			if (!rs_str_ok(&e, s->st_name))
				continue;
			rs_symset_add(set, e.strtab + s->st_name);
		}
	}
	rs_close(&e);
}

/*
 * First STRONG undefined symbol of `path` that `have` does not define, or NULL.
 *
 * Weak imports are skipped deliberately: _ITM_registerTMCloneTable and
 * __gmon_start__ are absent from every libc ever built and resolve to 0 by
 * design. Counting them would make every set look mixed.
 */
static const char *rs_first_unsatisfied(const char *path, const struct rs_symset *have,
                                        char *buf, size_t bufsz) {
	struct rs_elf e;
	size_t so, n;
	const char *found = NULL;
	if (!rs_open(&e, path))
		return NULL;
	if (rs_dynsym(&e, &so, &n)) {
		for (size_t i = 0; i < n && !found; i++) {
			const ElfW(Sym) *s = (const ElfW(Sym) *)(e.map + so + i * sizeof(ElfW(Sym)));
			if (s->st_shndx != SHN_UNDEF || !s->st_name)
				continue;
			if ((s->st_info >> 4) != STB_GLOBAL)
				continue;                /* weak: resolves to 0, never fatal */
			if (!rs_str_ok(&e, s->st_name))
				continue;
			const char *nm = e.strtab + s->st_name;
			if (!*nm || rs_symset_has(have, nm))
				continue;
			snprintf(buf, bufsz, "%s", nm);
			found = buf;
		}
	}
	rs_close(&e);
	return found;
}

/* ------------------------------------------------------- version compare */
/* Parse "GLIBC_2.41" into a comparable number. Non-GLIBC names sort lowest so
 * GLIBC_PRIVATE and GLIBC_ABI_DT_RELR never masquerade as a release. */
static long rs_relnum(const char *v) {
	unsigned a, b, c = 0;
	if (!v || strncmp(v, "GLIBC_", 6) != 0)
		return -1;
	int n = sscanf(v + 6, "%u.%u.%u", &a, &b, &c);
	if (n < 2)
		return -1;
	return (long)a * 1000000L + (long)b * 1000L + (long)c;
}

static long rs_max_release(const struct rs_vers *s, char *out, size_t outsz) {
	long best = -1;
	for (size_t i = 0; i < s->n; i++) {
		long r = rs_relnum(s->v[i]);
		if (r > best) {
			best = r;
			if (out)
				snprintf(out, outsz, "%s", s->v[i]);
		}
	}
	return best;
}

/* ------------------------------------------------------------ decision */

struct rs_plan {
	int use_host;
	char reason[512];
	char host_dir[RS_MAX_PATH];          /* libdir holding host libc */
	char host_ld[RS_MAX_PATH];           /* absolute path to the host ld.so */
	char bundled_ver[64];
	char host_ver[64];
	const char *members[16];             /* runtime members to farm */
	size_t member_count;
};

static int rs_exists(const char *dir, const char *file, char *out, size_t outsz) {
	snprintf(out, outsz, "%s/%s", dir, file);
	return access(out, R_OK) == 0;
}

/*
 * Highest GLIBC_x.y defined anywhere in a runtime set living in `dir`.
 *
 * Reading libc.so.6 alone is not enough: a release that adds no new libc
 * symbols leaves libc's top VERDEF at the previous release. Measured on
 * Debian bullseye, glibc 2.31, whose libc.so.6 tops out at GLIBC_2.30 while
 * libm.so.6 carries GLIBC_2.31. Both sides of the comparison must be measured
 * the same way or the ranking is not meaningful.
 */
static long rs_set_release(const char *dir, const struct rs_plan *p,
                           char *out, size_t outsz) {
	char path[RS_MAX_PATH];
	struct rs_vers all = {{0}, 0};

	for (size_t i = 0; i < p->member_count; i++)
		if (rs_exists(dir, p->members[i], path, sizeof(path)))
			rs_verdef(path, &all);

	/* member_count is zero on the very first call for the bundled side */
	if (!p->member_count)
		for (size_t i = 0; rs_runtime_set[i]; i++)
			if (rs_exists(dir, rs_runtime_set[i], path, sizeof(path)))
				rs_verdef(path, &all);

	long r = rs_max_release(&all, out, outsz);
	rs_vers_free(&all);
	return r;
}

/*
 * Is `dir` + `ldso` an INTERNALLY CONSISTENT glibc?
 *
 * This is the E11 guard, and it is the whole point of the exercise. It does
 * not ask "are the files there", because E11's mixed set had every file present. It
 * asks the question ld.so will ask at load time, ahead of time: does each
 * member's VERNEED on its peers fall inside what those peers DEFINE?
 *
 * The libc -> ld.so edge is the one E8 measured breaking:
 *     new libc.so.6 requires from ld-linux : ... GLIBC_2.35, GLIBC_PRIVATE
 *     old ld-linux  defines                : ... GLIBC_2.4
 * so checking it statically here is checking exactly the thing that failed.
 */
static int rs_set_consistent(struct rs_plan *p, const char **missing) {
	char path[RS_MAX_PATH];
	struct rs_vers ld_def = {{0}, 0}, libc_def = {{0}, 0}, need = {{0}, 0};
	int ok = 1;

	if (!rs_verdef(p->host_ld, &ld_def)) {
		*missing = "host ld.so has no version definitions";
		return 0;
	}
	if (!rs_exists(p->host_dir, "libc.so.6", path, sizeof(path))) {
		*missing = "libc.so.6";
		rs_vers_free(&ld_def);
		return 0;
	}
	if (!rs_verdef(path, &libc_def)) {
		*missing = "host libc.so.6 has no version definitions";
		rs_vers_free(&ld_def);
		return 0;
	}

	/* libc -> ld.so: the E8 edge. */
	rs_verneed_from(path, RS_LDSO, &need);
	for (size_t i = 0; i < need.n; i++) {
		if (!rs_vers_has(&ld_def, need.v[i])) {
			rs_log("MIXED SET: host libc.so.6 needs %s from " RS_LDSO
			       " which does not define it\n", need.v[i]);
			*missing = "host libc.so.6 and ld.so are from different glibc builds";
			ok = 0;
			break;
		}
	}
	rs_vers_free(&need);

	/* every other member -> libc: the E11 edge. */
	for (size_t m = 0; ok && m < p->member_count; m++) {
		const char *name = p->members[m];
		if (!strcmp(name, RS_LDSO) || !strcmp(name, "libc.so.6"))
			continue;
		if (!rs_exists(p->host_dir, name, path, sizeof(path)))
			continue;                    /* absence handled by the caller */
		struct rs_vers n2 = {{0}, 0};
		rs_verneed_from(path, "libc.so.6", &n2);
		for (size_t i = 0; i < n2.n; i++) {
			if (!rs_vers_has(&libc_def, n2.v[i])) {
				rs_log("MIXED SET: host %s needs %s from libc.so.6 which does "
				       "not define it\n", name, n2.v[i]);
				*missing = "host runtime members are from different glibc builds";
				ok = 0;
				break;
			}
		}
		rs_vers_free(&n2);
	}

	rs_vers_free(&ld_def);
	rs_vers_free(&libc_def);
	if (!ok)
		return 0;

	/* --- the E11 check proper: symbols, not version names --- */
	static struct rs_symset have;
	rs_symset_free(&have);
	if (rs_exists(p->host_dir, "libc.so.6", path, sizeof(path)))
		rs_collect_exports(path, &have);
	rs_collect_exports(p->host_ld, &have);
	if (rs_exists(p->host_dir, "libm.so.6", path, sizeof(path)))
		rs_collect_exports(path, &have);

	if (have.n < 100) {
		/* Could not read the host libc's symbol table. Refusing is the only
		 * safe answer: an unverifiable set is not a verified one. */
		*missing = "host libc symbol table unreadable, cannot verify the set";
		rs_symset_free(&have);
		return 0;
	}

	static char symbuf[256];
	for (size_t m = 0; m < p->member_count; m++) {
		const char *name = p->members[m];
		if (!strcmp(name, RS_LDSO) || !strcmp(name, "libc.so.6") ||
		    !strcmp(name, "libm.so.6"))
			continue;
		if (!rs_exists(p->host_dir, name, path, sizeof(path)))
			continue;
		const char *bad = rs_first_unsatisfied(path, &have, symbuf, sizeof(symbuf));
		if (bad) {
			rs_log("MIXED SET: host %s needs %s, which the host libc does not "
			       "define -- this is the E11 configuration\n", name, bad);
			*missing = symbuf;
			rs_symset_free(&have);
			return 0;
		}
	}

	rs_symset_free(&have);
	return 1;
}

/* Treat this directory as the host runtime instead of searching the usual
 * places. Exists so the E11 completeness guard can be tested against a
 * deliberately mixed set without having to corrupt a real system, and so a
 * user on an unusual layout can point at their own. Set by --host-dir. */
static const char *rs_host_dir_override;

static void rs_decide(struct rs_plan *p, const char *appdir) {
	char path[RS_MAX_PATH];
	const char *forced = cld_getenv("CROSS_LIBC_DLOPEN_RUNTIME", NULL);

	memset(p, 0, sizeof(*p));
	snprintf(p->bundled_ver, sizeof(p->bundled_ver), "unknown");
	snprintf(p->host_ver, sizeof(p->host_ver), "unknown");

	if (forced && !strcmp(forced, "host")) {
		/* still probe, so we can refuse an impossible force rather than
		 * exec into a segfault */
		rs_log("CROSS_LIBC_DLOPEN_RUNTIME=host: forced, still verifying the set\n");
	} else if (forced && !strcmp(forced, "bundled")) {
		snprintf(p->reason, sizeof(p->reason),
		         "CROSS_LIBC_DLOPEN_RUNTIME=bundled -- forced by the user");
		return;
	} else if (forced && *forced && strcmp(forced, "auto")) {
		snprintf(p->reason, sizeof(p->reason),
		         "CROSS_LIBC_DLOPEN_RUNTIME=%s is not host|bundled|auto; using bundled", forced);
		return;
	}

	if (!appdir || !*appdir) {
		snprintf(p->reason, sizeof(p->reason),
		         "no APPDIR: nothing bundled to compare against");
		return;
	}

	/* --- what do we bundle? --- */
	char blib[RS_MAX_PATH];
	snprintf(blib, sizeof(blib), "%s/%s", appdir, cld_libdir());
	if (!rs_exists(blib, "libc.so.6", path, sizeof(path))) {
		snprintf(p->reason, sizeof(p->reason),
		         "no bundled libc.so.6 under %s -- not a bundled-runtime root", blib);
		return;
	}
	/* Only the members we actually bundle are required of the host. A host
	 * missing libanl.so.1 is not incomplete if we never shipped one. */
	for (size_t i = 0; rs_runtime_set[i]; i++) {
		if (rs_exists(blib, rs_runtime_set[i], path, sizeof(path)) &&
		    p->member_count < sizeof(p->members) / sizeof(*p->members))
			p->members[p->member_count++] = rs_runtime_set[i];
	}

	/* The release is the highest GLIBC_x.y ANY member defines, not just
	 * libc.so.6's. Measured: glibc 2.31's libc.so.6 tops out at GLIBC_2.30
	 * because that release added no new libc symbols, so reading libc alone
	 * reports the wrong release and would misrank two close hosts. */
	long bver = rs_set_release(blib, p, p->bundled_ver, sizeof(p->bundled_ver));
	if (bver < 0) {
		snprintf(p->reason, sizeof(p->reason),
		         "bundled runtime defines no GLIBC_x.y version");
		return;
	}

	/* --- find a host libdir holding the WHOLE set --- */
	const char *why_incomplete = NULL;
	const char *only_dir[2] = { rs_host_dir_override, NULL };
	const char **search = rs_host_dir_override ? only_dir : rs_host_libdirs;

	for (size_t d = 0; search[d]; d++) {
		const char *dir = search[d];
		if (!rs_exists(dir, "libc.so.6", path, sizeof(path)))
			continue;

		/* Ignore our own bundled dir if it happens to be on the list. */
		if (!strncmp(dir, appdir, strlen(appdir)))
			continue;

		size_t have = 0;
		const char *first_missing = NULL;
		for (size_t m = 0; m < p->member_count; m++) {
			if (!strcmp(p->members[m], RS_LDSO))
				continue;                /* located separately below */
			if (rs_exists(dir, p->members[m], path, sizeof(path)))
				have++;
			else if (!first_missing)
				first_missing = p->members[m];
		}
		if (first_missing) {
			rs_log("host dir %s incomplete: missing %s\n", dir, first_missing);
			why_incomplete = "host is missing a runtime member we bundle";
			continue;
		}

		snprintf(p->host_dir, sizeof(p->host_dir), "%s", dir);

		/* ld.so may live in a different directory than libc (Debian puts
		 * libc in the triplet dir and ld.so in /lib64). Try alongside libc
		 * first, then the usual homes. */
		p->host_ld[0] = '\0';
		if (rs_exists(dir, RS_LDSO, path, sizeof(path)))
			snprintf(p->host_ld, sizeof(p->host_ld), "%s", path);
		else
			for (size_t k = 0; search[k]; k++)
				if (rs_exists(search[k], RS_LDSO, path, sizeof(path))) {
					snprintf(p->host_ld, sizeof(p->host_ld), "%s", path);
					break;
				}
		if (!p->host_ld[0]) {
			rs_log("host dir %s has no " RS_LDSO "\n", dir);
			why_incomplete = "host has no dynamic loader we can find";
			p->host_dir[0] = '\0';
			continue;
		}
		break;
	}

	if (!p->host_dir[0]) {
		snprintf(p->reason, sizeof(p->reason), "%s",
		         why_incomplete ? why_incomplete
		                        : "no host glibc found (musl host, or none) "
		                          "-- bundled runtime + shim is the only option");
		return;
	}

	/* --- host version, measured the same way as the bundled one --- */
	long hver = rs_set_release(p->host_dir, p, p->host_ver, sizeof(p->host_ver));

	if (hver < 0) {
		snprintf(p->reason, sizeof(p->reason),
		         "host libc.so.6 defines no GLIBC_x.y version");
		return;
	}

	/* --- the decision matrix (see ../docs/report/README.md) --- */
	if (hver <= bver && !(forced && !strcmp(forced, "host"))) {
		snprintf(p->reason, sizeof(p->reason),
		         "host glibc %s is not newer than bundled %s -- old host libraries "
		         "cannot require newer symbols, so there is nothing to bridge",
		         p->host_ver, p->bundled_ver);
		return;
	}

	/* --- completeness (E11) --- */
	const char *missing = NULL;
	if (!rs_set_consistent(p, &missing)) {
		snprintf(p->reason, sizeof(p->reason),
		         "host glibc %s is newer than bundled %s but the set is NOT "
		         "internally consistent (%s) -- switching a mixed set segfaults, "
		         "so keeping bundled", p->host_ver, p->bundled_ver, missing);
		return;
	}

	p->use_host = 1;
	snprintf(p->reason, sizeof(p->reason),
	         "host glibc %s is newer than bundled %s and the whole set in %s is "
	         "internally consistent", p->host_ver, p->bundled_ver, p->host_dir);
}

/* ------------------------------------------------------- symlink farm */
/*
 * A directory containing ONLY the host runtime set, so it can go ahead of
 * $APPDIR/lib without the host winning every other soname (T4.2).
 *
 * Symlinks, under XDG_RUNTIME_DIR: no host file is read, written or replaced,
 * which is what keeps T4.3 (host checksums unchanged) true.
 */
static int rs_build_farm(const struct rs_plan *p, char *out, size_t outsz) {
	const char *base = getenv("XDG_RUNTIME_DIR");
	if (!base || !*base)
		base = getenv("TMPDIR");
	if (!base || !*base)
		base = "/tmp";

	snprintf(out, outsz, "%s/.cross-libc-dlopen-hostrt-%s", base,
	         p->host_ver[0] ? p->host_ver : "unknown");
	if (mkdir(out, 0700) != 0 && errno != EEXIST) {
		rs_log("cannot create runtime farm %s: %s\n", out, strerror(errno));
		return 0;
	}

	char src[RS_MAX_PATH], dst[RS_MAX_PATH];
	for (size_t m = 0; m < p->member_count; m++) {
		const char *name = p->members[m];
		if (!strcmp(name, RS_LDSO))
			continue;                    /* the loader is named directly */
		snprintf(src, sizeof(src), "%s/%s", p->host_dir, name);
		if (access(src, R_OK) != 0)
			continue;
		snprintf(dst, sizeof(dst), "%s/%s", out, name);
		unlink(dst);
		if (symlink(src, dst) != 0 && errno != EEXIST) {
			rs_log("cannot link %s -> %s: %s\n", dst, src, strerror(errno));
			return 0;
		}
	}
	return 1;
}

/* ------------------------------------------------------------ exec */

/* Append one directory, once, guarding both the buffer and duplicates.
 * Returns 0 when it would not fit, so the caller can say so rather than
 * silently shipping a truncated path, one that is quietly one directory
 * short is exactly the failure E44 is about. */
static int rs_path_append(char *s, size_t cap, size_t *n, const char *dir) {
	size_t len = strlen(dir);
	if (!len)
		return 1;
	/* Already there? Match on whole components, so /usr/lib does not swallow
	 * /usr/lib64. */
	for (const char *at = s; at; ) {
		const char *end = strchr(at, ':');
		size_t seg = end ? (size_t)(end - at) : strlen(at);
		if (seg == len && !strncmp(at, dir, len))
			return 1;
		at = end ? end + 1 : NULL;
	}
	struct stat st;
	if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
		return 1;
	if (*n + 1 + len + 1 > cap)
		return 0;
	s[(*n)++] = ':';
	memcpy(s + *n, dir, len + 1);
	*n += len;
	return 1;
}

/* Every directory the DISTRO itself considers a library directory.
 *
 * The hardcoded list elsewhere covers the conventional places. It does not
 * cover the unconventional ones, and E44 is what that costs: WSL puts the GPU
 * vendor userspace in /usr/lib/wsl/lib and makes it reachable ONLY by writing
 * /etc/ld.so.conf.d/ld.wsl.conf. Under a loader with the cache inhibited (E13b)
 * that directory does not exist as far as the process is concerned, NVIDIA's
 * libcuda.so.1 cannot dlopen its own libdxcore.so, and CUDA reports no device
 * at all, a symptom that reads as "no GPU", not as a missing library.
 *
 * The walk itself lives in ld-conf.h, because src/gl-fwd.c needs the same
 * answer for a different reason and a second parser is how the two would
 * drift. What stays here is the part that is about THIS caller: appending to a
 * bounded --library-path, and this file's own logger.
 */
struct rs_conf_ctx {
	char  *s;
	size_t cap;
	size_t *n;
};

static int rs_conf_add(const char *dir, void *ctx) {
	struct rs_conf_ctx *c = ctx;
	if (!rs_path_append(c->s, c->cap, c->n, dir))
		rs_log("library-path is full; %s omitted\n", dir);
	return 0;                       /* never stop: we want every directory */
}

static void rs_conf_warn(void *ctx, const char *what, const char *detail) {
	(void)ctx;
	if (detail)
		rs_log("%s: %s\n", what, detail);
	else
		rs_log("%s\n", what);
}

static void rs_conf_dirs(const char *path, char *s, size_t cap, size_t *n) {
	struct rs_conf_ctx c;
	c.s = s;
	c.cap = cap;
	c.n = n;
	ldconf_each_dir(path, rs_conf_add, rs_conf_warn, &c);
}

static char *rs_library_path(const struct rs_plan *p, const char *appdir,
                             const char *farm) {
	/* farm : appdir/lib : host dirs.  Order IS the design (T4.2): the farm
	 * carries the libc runtime and nothing else, the AppDir wins for
	 * everything bundled, and host directories are a fallback for what the
	 * bundle lacks. Everything added below is appended, never inserted. */
	size_t cap = 8192;
	char *s = malloc(cap);
	if (!s)
		return NULL;
	int wrote = snprintf(s, cap, "%s:%s/%s:%s", farm, appdir, cld_libdir(),
	                     p->host_dir);
	if (wrote < 0 || (size_t)wrote >= cap) {
		free(s);
		return NULL;
	}
	size_t n = (size_t)wrote;
	for (size_t i = 0; rs_host_libdirs[i]; i++)
		if (!rs_path_append(s, cap, &n, rs_host_libdirs[i]))
			rs_log("library-path is full; %s omitted\n", rs_host_libdirs[i]);
	/* The budget and its one-shot warning are per-walk state inside
	 * ldconf_each_dir now, so there is nothing to reset here. */
	rs_conf_dirs("/etc/ld.so.conf", s, cap, &n);
	return s;
}

/*
 * Where is this binary on disk?
 *
 * /proc/self/exe is the obvious answer and it is WRONG here. Inside an
 * AppImage this program is started as
 *
 *     $APPDIR/lib/ld-linux-x86-64.so.2 --library-path $APPDIR/lib runtime-select
 *
 * and when a loader is invoked explicitly the kernel exec'd the LOADER, so
 * /proc/self/exe names ld-linux, not us. Re-execing that under the host loader
 * asks one dynamic linker to run another as a program; it exits 127, which is
 * indistinguishable from a genuinely broken runtime. Measured: every newer
 * host reported a false "SELF-TEST FAILED" until this was fixed.
 *
 * So: trust /proc/self/exe only when it does not name a loader, and fall back
 * to argv[0].
 */
static void rs_resolve_self(const char *argv0, char *out, size_t outsz) {
	char buf[RS_MAX_PATH];
	out[0] = '\0';

	ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
	if (n > 0) {
		buf[n] = '\0';
		const char *base = strrchr(buf, '/');
		base = base ? base + 1 : buf;
		if (strncmp(base, "ld-", 3) != 0) {
			snprintf(out, outsz, "%s", buf);
			return;
		}
		rs_log("/proc/self/exe is %s (a loader); using argv[0] instead\n", buf);
	}

	if (!argv0 || !*argv0)
		return;

	if (strchr(argv0, '/')) {
		char *real = realpath(argv0, NULL);
		if (real) {
			snprintf(out, outsz, "%s", real);
			free(real);
		} else {
			snprintf(out, outsz, "%s", argv0);
		}
		return;
	}

	/* bare name: walk PATH the way execvp would */
	const char *path = getenv("PATH");
	if (!path || !*path)
		return;
	const char *p = path;
	while (*p) {
		const char *sep = strchr(p, ':');
		size_t len = sep ? (size_t)(sep - p) : strlen(p);
		if (len && len < sizeof(buf) - strlen(argv0) - 2) {
			memcpy(buf, p, len);
			buf[len] = '\0';
			strcat(buf, "/");
			strcat(buf, argv0);
			if (access(buf, X_OK) == 0) {
				snprintf(out, outsz, "%s", buf);
				return;
			}
		}
		if (!sep)
			break;
		p = sep + 1;
	}
}

/*
 * The self-test child: exercise the parts of libc a mixed set breaks.
 *
 * E11's segfault came from an old libdl.so.2 against a new libc.so.6, and it
 * died inside a dlopen. So it is not enough to start and exit: touch the
 * allocator, TLS (errno), stdio, and the dynamic linker interface, which is
 * where the crash actually lives.
 */
static int rs_self_test_child(void) {
	void *p = malloc(4096);
	if (!p)
		return 1;
	memset(p, 0x5a, 4096);

	errno = 0;                           /* TLS */
	FILE *f = fopen("/dev/null", "w");   /* stdio + FILE locks */
	if (f) {
		fprintf(f, "%d%s", 1, "x");
		fclose(f);
	}
	if (errno == -1)                     /* never true; stops the read being elided */
		return 1;

	/* The E11 crash site. RTLD_NOLOAD so nothing new is mapped. */
	void *h = dlopen("libc.so.6", RTLD_NOW | RTLD_NOLOAD);
	if (h)
		(void)dlsym(h, "malloc");

	free(p);
	return 0;
}

/*
 * Verify the plan by running something under it before committing.
 *
 * The consistency check above is a static prediction. E11 is a segfault, and
 * a segfault is cheap to observe: fork, re-exec OURSELVES under the candidate
 * runtime, and see whether we die.
 *
 * Re-execing this binary rather than the host's /bin/true is deliberate on two
 * counts. First it is guaranteed to be a dynamically linked ELF, measured:
 * Rocky 9's /bin/true is a 51-byte shell script, and ld.so answers "file too
 * short", which looked exactly like a mixed set and was not. Second it is the
 * stronger question: this binary was linked against the BUNDLED glibc, so the
 * test asks whether our own objects survive the host runtime, which is what
 * we are actually about to do.
 */
static int rs_self_test(const struct rs_plan *p, const char *libpath,
                        const char *self) {
	if (!self || !*self) {
		rs_log("self-test skipped: cannot locate this binary\n");
		return 1;                        /* cannot test is not the same as failed */
	}

	pid_t pid = fork();
	if (pid < 0) {
		rs_log("self-test skipped: fork failed (%s)\n", strerror(errno));
		return 1;
	}
	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, 1);
			dup2(devnull, 2);
		}
		char *argv[] = { (char *)p->host_ld, (char *)"--library-path",
		                 (char *)libpath, (char *)self,
		                 (char *)"--self-test-child", NULL };
		execv(p->host_ld, argv);
		_exit(127);
	}

	int status = 0;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	if (WIFSIGNALED(status)) {
		rs_log("SELF-TEST FAILED: probe died on signal %d -- this is the E11 "
		       "shape. Keeping the bundled runtime.\n", WTERMSIG(status));
		return 0;
	}
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		rs_log("SELF-TEST FAILED: probe exited %d. Keeping bundled.\n",
		       WIFEXITED(status) ? WEXITSTATUS(status) : -1);
		return 0;
	}
	rs_log("self-test passed: this binary ran clean under the host runtime\n");
	return 1;
}

static void rs_print_plan(const struct rs_plan *p, const char *appdir) {
	printf("runtime      : %s\n", p->use_host ? "host" : "bundled");
	printf("reason       : %s\n", p->reason);
	printf("bundled glibc: %s\n", p->bundled_ver);
	printf("host glibc   : %s\n", p->host_ver);
	printf("host libdir  : %s\n", p->host_dir[0] ? p->host_dir : "(none)");
	printf("host ld.so   : %s\n", p->host_ld[0] ? p->host_ld : "(none)");
	printf("appdir       : %s\n", appdir ? appdir : "(unset)");
	printf("runtime set  :");
	for (size_t i = 0; i < p->member_count; i++)
		printf(" %s", p->members[i]);
	printf("\n");
}

int main(int argc, char **argv) {
	const char *dbg = cld_getenv("CROSS_LIBC_DLOPEN_DEBUG", NULL);
	rs_debug = dbg && !strcmp(dbg, "1");

	const char *appdir = cld_root();
	int probe_only = 0, argi = 1, no_self_test = 0;

	/* Checked before anything else: this is the forked child of a self-test,
	 * already running under the candidate runtime. */
	if (argc == 2 && !strcmp(argv[1], "--self-test-child"))
		return rs_self_test_child();

	for (; argi < argc; argi++) {
		if (!strcmp(argv[argi], "--probe")) {
			probe_only = 1;
		} else if (!strcmp(argv[argi], "--no-self-test")) {
			no_self_test = 1;
		} else if (!strcmp(argv[argi], "--appdir") && argi + 1 < argc) {
			appdir = argv[++argi];
		} else if (!strcmp(argv[argi], "--host-dir") && argi + 1 < argc) {
			rs_host_dir_override = argv[++argi];
		} else if (!strcmp(argv[argi], "--")) {
			argi++;
			break;
		} else if (argv[argi][0] == '-') {
			fprintf(stderr, "runtime-select: unknown option %s\n", argv[argi]);
			return 2;
		} else {
			break;
		}
	}

	char self_path[RS_MAX_PATH];
	rs_resolve_self(argv[0], self_path, sizeof(self_path));

	struct rs_plan plan;
	rs_decide(&plan, appdir);
	rs_log("decision: %s -- %s\n", plan.use_host ? "HOST" : "BUNDLED", plan.reason);

	char farm[RS_MAX_PATH] = "";
	char *libpath = NULL;

	if (plan.use_host) {
		if (!rs_build_farm(&plan, farm, sizeof(farm))) {
			plan.use_host = 0;
			snprintf(plan.reason, sizeof(plan.reason),
			         "could not build the runtime symlink farm; keeping bundled");
		} else {
			libpath = rs_library_path(&plan, appdir, farm);
			if (!libpath) {
				plan.use_host = 0;
				snprintf(plan.reason, sizeof(plan.reason),
				         "could not assemble --library-path; keeping bundled");
			} else if (!no_self_test && !rs_self_test(&plan, libpath, self_path)) {
				plan.use_host = 0;
				snprintf(plan.reason, sizeof(plan.reason),
				         "the host runtime failed a self-test (the E11 shape); "
				         "keeping bundled");
			}
		}
	}

	if (probe_only) {
		rs_print_plan(&plan, appdir);
		if (plan.use_host && libpath)
			printf("library-path : %s\n", libpath);
		free(libpath);
		return 0;
	}

	if (argi >= argc) {
		fprintf(stderr, "runtime-select: nothing to exec "
		                "(use --probe, or -- CMD ARGS...)\n");
		free(libpath);
		return 2;
	}

	if (!plan.use_host) {
		/* Bundled: exec straight through, the AppDir's own launcher takes it
		 * from here. Nothing about the process changes. */
		execvp(argv[argi], &argv[argi]);
		fprintf(stderr, "runtime-select: exec %s: %s\n", argv[argi], strerror(errno));
		return 127;
	}

	/* Host: re-exec under the host loader with our assembled path. */
	int extra = argc - argi;
	char **av = calloc((size_t)extra + 5, sizeof(char *));
	if (!av)
		return 1;
	int k = 0;
	av[k++] = plan.host_ld;
	av[k++] = (char *)"--library-path";
	av[k++] = libpath;
	for (int i = argi; i < argc; i++)
		av[k++] = argv[i];
	av[k] = NULL;

	rs_log("exec: %s --library-path %s %s ...\n", plan.host_ld, libpath, argv[argi]);
	execv(plan.host_ld, av);
	fprintf(stderr, "runtime-select: exec %s: %s\n", plan.host_ld, strerror(errno));
	return 127;
}
