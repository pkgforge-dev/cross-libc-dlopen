/* Cross-libc dlopen loader
 *
 * Loads OpenGL/Vulkan drivers, and their dependency closure, from the HOST
 * system even when those were built against a different libc such as a newer
 * glibc or musl, instead of shipping any driver in the bundle. The host libc
 * itself never enters the process.
 *
 * A host object's symbol version requirements are stripped from a private
 * memfd copy, which turns every reference into a plain name lookup against
 * whatever is already loaded. Every version tag goes at once: a verdef left
 * without its versym table segfaults ld.so. A musl-built object carries no
 * version information to begin with and rides the same dependency resolver.
 *
 * Anything outside the bundle root counts as a host library. Sharun already
 * hands the dynamic linker the full search list, so bundled libraries keep
 * winning.
 *
 * ON BY DEFAULT whenever this object is preloaded, because preloading it is
 * already the deliberate act. CROSS_LIBC_DLOPEN=0 turns it off, which is what
 * every A/B control uses for its "feature off" arm.
 *
 * REQUIREMENT, not advice about one consumer: this object's pass-throughs
 * must run AFTER any other dlopen interposer in the process, so that
 * whatever that interposer does to a dlopen still happens first.
 *
 * Modified version of the foreign dlopen mode previously living in
 * https://github.com/pkgforge-dev/Anylinux-AppImages useful-tools/lib/anylinux.c
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <link.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "cld-env.h"

typedef void *(*dlopen_func_t)(const char *filename, int flags);

#define VISIBLE __attribute__((visibility("default")))

static int cross_libc_dlopen_debug_enabled(void) {
	const char *v = cld_getenv("CROSS_LIBC_DLOPEN_DEBUG", NULL);
	return v && strcmp(v, "1") == 0;
}

// Every trace line carries the object's own name, because a process under this
// loader has more than one preload writing to stderr.
#define DEBUG_PRINT(...) do \
	if (cross_libc_dlopen_debug_enabled()) \
		fprintf(stderr, " [cross-libc-dlopen.so] >> " __VA_ARGS__); \
	while (0)

// unknown dynamic tags are ignored by ld.so
#define CLD_NEUTRAL_TAG 0x414e594c /* 'ANYL' */

// prefix for the rewritten images emitted next to XDG_RUNTIME_DIR
#define CLD_TMP_PREFIX ".cross-libc-dlopen-"

#ifndef MFD_CLOEXEC
#define MFD_CLOEXEC 1U
#endif

// ⭐ ON BY DEFAULT. Preloading this object is already an explicit, deliberate
// act by whoever assembled the process: nothing loads it by accident. Asking
// for a second opt-in on top of that, whether an environment variable or a
// marker file at the bundle root, bought nothing and cost a whole class of silent
// failure, where a consumer preloads the object, forgets the marker, and gets
// a run that does nothing and says nothing about why.
//
// ⛔ THE OFF SWITCH IS LOAD-BEARING. CROSS_LIBC_DLOPEN=0 is what every A/B
// control in experiments/40-appimage.sh sets for its "feature off" arm, and
// what E23 sets to measure version-compat.c's definitions with no dlopen
// interception in the process. An arm that leaves the variable unset measures
// the feature ON, and reports whatever it predicted.
//
// Anything other than 0 is on, including an empty value, so
// CROSS_LIBC_DLOPEN= reads as "present and not disabling" rather than as
// "unset". =1 still forces it on and is still what the documents show.
static int cross_libc_dlopen_mode(void) {
	const char *v = getenv("CROSS_LIBC_DLOPEN");
	if (v && strcmp(v, "0") == 0)
		return 0;
	return 1;
}

// Rewritten images pile up on tmpfs across runs, clear out anything
// older than a day before going about our business
__attribute__((constructor))
static void sweep_stale_cld_tmp(void) {
	if (!cross_libc_dlopen_mode())
		return;

	const char *dir = getenv("XDG_RUNTIME_DIR");
	if (!dir || !*dir)
		dir = getenv("TMPDIR");
	if (!dir || !*dir)
		dir = "/tmp";

	DIR *d = opendir(dir);
	if (!d)
		return;

	time_t cutoff = time(NULL) - 86400;
	struct dirent *de;
	char path[PATH_MAX];
	while ((de = readdir(d))) {
		if (strncmp(de->d_name, CLD_TMP_PREFIX, strlen(CLD_TMP_PREFIX)) != 0 &&
		    strncmp(de->d_name, CLD_TMP_PREFIX + 1, strlen(CLD_TMP_PREFIX) - 1) != 0)
			continue;
		snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
		struct stat st;
		if (stat(path, &st) == 0 && st.st_mtime < cutoff)
			unlink(path);
	}
	closedir(d);
}

static int is_host_library_path(const char *path) {
	const char *appdir = cld_root();

	if (!path || *path != '/')
		return 0;

	// never treat anything shipped inside the bundle as a host library,
	// mind the boundary so /opt/app does not swallow /opt/app-other
	if (appdir && *appdir) {
		size_t len = strlen(appdir);
		while (len > 1 && appdir[len - 1] == '/')
			len--;
		if (strncmp(path, appdir, len) == 0 && (path[len] == '\0' || path[len] == '/'))
			return 0;
	}

	return 1;
}

struct cld_elf {
	char *map;               // whole file contents, mutable private copy
	size_t size;
	const ElfW(Ehdr) *ehdr;
	const ElfW(Phdr) *phdr;
	int phnum;
	ElfW(Dyn) *dyn;          // dynamic array inside map
	size_t dyn_num;
	const char *strtab;      // dynamic string table inside map
	size_t strsz;
	ElfW(Sym) *dynsym;       // dynamic symbol table inside map, NULL when absent
	size_t dynsym_num;
	size_t gnu_symoffset;    // DT_GNU_HASH symoffset: first HASHED symbol index
};

// Translate a virtual address to a file offset through the PT_LOAD headers,
// (size_t)-1 when not backed by the file
static size_t cld_vaddr_to_offset(const struct cld_elf *e, ElfW(Addr) vaddr) {
	for (int i = 0; i < e->phnum; i++) {
		if (e->phdr[i].p_type != PT_LOAD)
			continue;
		if (vaddr >= e->phdr[i].p_vaddr && vaddr < e->phdr[i].p_vaddr + e->phdr[i].p_filesz) {
			size_t off = (size_t)(e->phdr[i].p_offset + (vaddr - e->phdr[i].p_vaddr));
			if (off < e->size)
				return off;
			return (size_t)-1;
		}
	}
	return (size_t)-1;
}

static void cld_free_elf(struct cld_elf *e) {
	free(e->map);
	memset(e, 0, sizeof(*e));
}

// Locate .dynsym and work out how many entries it has.
//
// There is no DT_ tag for the symbol count. ld.so never needs one: it reaches
// symbols through the hash tables. We do need one, because the ___environ
// remap (Design B) walks the table. Two sources, in order of trust:
//
//   DT_HASH    nchain IS the symbol count, exactly. Authoritative.
//   DT_GNU_HASH  no count; the last hashed symbol is found by walking the
//                bucket with the highest start index until the chain's
//                terminator bit. symoffset also tells us where the HASHED
//                region begins, which is what makes the remap safe: every
//                index below it is undefined and therefore unhashed.
//
// Anything we cannot bound leaves dynsym NULL and the remap simply declines.
static void cld_locate_dynsym(struct cld_elf *e) {
	ElfW(Addr) symtab_vaddr = 0, hash_vaddr = 0, gnu_hash_vaddr = 0;
	ElfW(Xword) syment = sizeof(ElfW(Sym));

	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		switch (e->dyn[i].d_tag) {
		case DT_SYMTAB:   symtab_vaddr   = (ElfW(Addr))e->dyn[i].d_un.d_ptr; break;
		case DT_SYMENT:   syment         = (ElfW(Xword))e->dyn[i].d_un.d_val; break;
		case DT_HASH:     hash_vaddr     = (ElfW(Addr))e->dyn[i].d_un.d_ptr; break;
		case DT_GNU_HASH: gnu_hash_vaddr = (ElfW(Addr))e->dyn[i].d_un.d_ptr; break;
		default: break;
		}
	}
	if (!symtab_vaddr || syment != sizeof(ElfW(Sym)))
		return;

	size_t symoff = cld_vaddr_to_offset(e, symtab_vaddr);
	if (symoff == (size_t)-1)
		return;

	size_t count = 0;

	if (hash_vaddr) {
		size_t ho = cld_vaddr_to_offset(e, hash_vaddr);
		if (ho != (size_t)-1 && ho + 2 * sizeof(uint32_t) <= e->size) {
			uint32_t nchain;
			memcpy(&nchain, e->map + ho + sizeof(uint32_t), sizeof(nchain));
			count = nchain;
		}
	}

	if (gnu_hash_vaddr) {
		size_t go = cld_vaddr_to_offset(e, gnu_hash_vaddr);
		if (go != (size_t)-1 && go + 4 * sizeof(uint32_t) <= e->size) {
			uint32_t hdr[4];
			memcpy(hdr, e->map + go, sizeof(hdr));
			uint32_t nbucket = hdr[0], symoffset = hdr[1], bloom_size = hdr[2];
			e->gnu_symoffset = symoffset;

			// Only walk the chains when DT_HASH did not already give us
			// an exact count: nchain is authoritative, this is not.
			if (!count && nbucket && nbucket < (1u << 24) && bloom_size < (1u << 24)) {
				size_t bo = go + 4 * sizeof(uint32_t) + (size_t)bloom_size * sizeof(ElfW(Addr));
				if (bo + (size_t)nbucket * sizeof(uint32_t) <= e->size) {
					uint32_t last = symoffset;
					for (uint32_t i = 0; i < nbucket; i++) {
						uint32_t b;
						memcpy(&b, e->map + bo + (size_t)i * sizeof(uint32_t), sizeof(b));
						if (b > last)
							last = b;
					}
					size_t co = bo + (size_t)nbucket * sizeof(uint32_t);
					if (last >= symoffset) {
						uint32_t idx = last - symoffset;
						// bounded: the chain array cannot exceed the file
						while (co + ((size_t)idx + 1) * sizeof(uint32_t) <= e->size) {
							uint32_t h;
							memcpy(&h, e->map + co + (size_t)idx * sizeof(uint32_t), sizeof(h));
							if (h & 1)
								break;
							idx++;
						}
						count = (size_t)symoffset + idx + 1;
					} else {
						count = symoffset;
					}
				}
			}
		}
	}

	if (!count)
		return;
	if (count > (e->size - symoff) / sizeof(ElfW(Sym)))
		return;                          // count disagrees with the file, distrust it

	e->dynsym = (ElfW(Sym) *)(e->map + symoff);
	e->dynsym_num = count;
}

static int cld_parse_elf(struct cld_elf *e, const char *path) {
	memset(e, 0, sizeof(*e));

	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;

	struct stat st;
	// no driver closure comes close to 1 GiB
	if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(ElfW(Ehdr)) || st.st_size > ((off_t)1 << 30)) {
		close(fd);
		return 0;
	}
	e->size = (size_t)st.st_size;

	e->map = malloc(e->size);
	if (!e->map) {
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
			cld_free_elf(e);
			return 0;
		}
		done += (size_t)n;
	}
	close(fd);

	e->ehdr = (const ElfW(Ehdr) *)e->map;
	if (memcmp(e->ehdr->e_ident, ELFMAG, SELFMAG) != 0 ||
	    e->ehdr->e_ident[EI_DATA] != ELFDATA2LSB ||
	    e->ehdr->e_type != ET_DYN ||
	    e->ehdr->e_ident[EI_CLASS] != (sizeof(void *) == 8 ? ELFCLASS64 : ELFCLASS32)) {
		cld_free_elf(e);
		return 0;
	}

	if (!e->ehdr->e_phnum || e->ehdr->e_phnum > 4096 ||
	    e->ehdr->e_phoff >= e->size ||
	    e->ehdr->e_phoff + (size_t)e->ehdr->e_phnum * sizeof(ElfW(Phdr)) > e->size) {
		cld_free_elf(e);
		return 0;
	}
	e->phdr = (const ElfW(Phdr) *)(e->map + e->ehdr->e_phoff);
	e->phnum = (int)e->ehdr->e_phnum;

	// keep hostile PT_LOAD headers in bounds
	for (int i = 0; i < e->phnum; i++) {
		if (e->phdr[i].p_type != PT_LOAD)
			continue;
		if (e->phdr[i].p_offset >= e->size ||
		    e->phdr[i].p_filesz > e->size - e->phdr[i].p_offset) {
			cld_free_elf(e);
			return 0;
		}
	}

	for (int i = 0; i < e->phnum; i++) {
		if (e->phdr[i].p_type != PT_DYNAMIC)
			continue;
		if (e->phdr[i].p_offset >= e->size ||
		    e->phdr[i].p_filesz > e->size - e->phdr[i].p_offset ||
		    e->phdr[i].p_filesz < sizeof(ElfW(Dyn)))
			break;
		e->dyn = (ElfW(Dyn) *)(e->map + e->phdr[i].p_offset);
		e->dyn_num = e->phdr[i].p_filesz / sizeof(ElfW(Dyn));
		break;
	}
	if (!e->dyn) {
		cld_free_elf(e);
		return 0;
	}

	ElfW(Addr) strtab_vaddr = 0;
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		if (e->dyn[i].d_tag == DT_STRTAB)
			strtab_vaddr = (ElfW(Addr))e->dyn[i].d_un.d_ptr;
		else if (e->dyn[i].d_tag == DT_STRSZ)
			e->strsz = (size_t)e->dyn[i].d_un.d_val;
	}
	if (strtab_vaddr) {
		size_t off = cld_vaddr_to_offset(e, strtab_vaddr);
		if (off != (size_t)-1 && off + e->strsz <= e->size)
			e->strtab = e->map + off;
	}

	cld_locate_dynsym(e);

	return 1;
}

static int cld_dyn_find(const struct cld_elf *e, ElfW(Sxword) tag, ElfW(Addr) *out) {
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		if (e->dyn[i].d_tag == tag) {
			*out = (ElfW(Addr))e->dyn[i].d_un.d_ptr;
			return 1;
		}
	}
	return 0;
}

// only trust strings terminated inside the string table
static int cld_valid_cstr(const struct cld_elf *e, size_t off) {
	if (!e->strtab || off >= e->strsz)
		return 0;
	return memchr(e->strtab + off, '\0', e->strsz - off) != NULL;
}

static int cld_has_version_tags(const struct cld_elf *e) {
	ElfW(Addr) dummy;
	return cld_dyn_find(e, DT_VERSYM, &dummy) || cld_dyn_find(e, DT_VERNEED, &dummy);
}

// versions our own libc provides, decides if a host object loads as-is
#define CLD_MAX_VERSIONS 1024
static char *cld_provider_versions[CLD_MAX_VERSIONS];
static size_t cld_provider_version_count;
static int cld_providers_scanned;

// Walk this object's DT_VERDEF entries.
//
// `visit` returns non-zero to stop. Every offset is bounds-checked against the
// mapped file before it is dereferenced: vd_aux, vd_next and vda_name all come
// out of the file, and a truncated or hostile object can point them anywhere.
//
// One walker rather than three. There were three copies of this loop, each
// bounding itself slightly differently and none of them bounding vd_aux at all,
// which is exactly the drift the "two implementations, one of them buggy" rule
// exists to prevent.
static void cld_walk_verdefs(const struct cld_elf *e,
                             int (*visit)(void *ctx, const char *name,
                                          ElfW(Half) ndx, int is_base),
                             void *ctx) {
	ElfW(Addr) vd_vaddr = 0;
	if (!cld_dyn_find(e, DT_VERDEF, &vd_vaddr) || !e->strtab)
		return;
	size_t off = cld_vaddr_to_offset(e, vd_vaddr);
	if (off == (size_t)-1)
		return;

	const char *base = e->map + off;
	size_t avail = e->size - off;
	size_t pos = 0;
	for (size_t guard = 0; guard < 4096; guard++) {
		if (pos > avail || avail - pos < sizeof(ElfW(Verdef)))
			return;
		const ElfW(Verdef) *vd = (const ElfW(Verdef) *)(base + pos);
		if (vd->vd_version != 1)
			return;

		const char *name = NULL;
		if (vd->vd_aux) {
			// vd_aux is a 32-bit offset from this Verdef, so the sum
			// cannot wrap a size_t; it can still land past the file.
			size_t apos = pos + (size_t)vd->vd_aux;
			if (apos <= avail && avail - apos >= sizeof(ElfW(Verdaux))) {
				const ElfW(Verdaux) *aux = (const ElfW(Verdaux) *)(base + apos);
				if (cld_valid_cstr(e, aux->vda_name))
					name = e->strtab + aux->vda_name;
			}
		}
		if (name && visit(ctx, name, vd->vd_ndx, (vd->vd_flags & VER_FLG_BASE) != 0))
			return;

		if (!vd->vd_next)
			return;
		pos += vd->vd_next;
	}
}

static int cld_collect_one(void *ctx, const char *name, ElfW(Half) ndx, int is_base) {
	(void)ctx; (void)ndx;
	// the VER_FLG_BASE entry names the file itself, not a version
	if (!is_base && cld_provider_version_count < CLD_MAX_VERSIONS)
		cld_provider_versions[cld_provider_version_count++] = strdup(name);
	return 0;
}

static void cld_collect_versions_from_file(const char *path) {
	struct cld_elf e;
	if (!cld_parse_elf(&e, path))
		return;
	cld_walk_verdefs(&e, cld_collect_one, NULL);
	cld_free_elf(&e);
}

#define CLD_CACHE_MAX 128
static struct {
	char *key;    // canonicalized source path
	void *handle; // dlopen handle once fully loaded
} cld_cache[CLD_CACHE_MAX];
static volatile int cld_cache_lock;

static void cld_lock_cache(void) {
	while (__sync_lock_test_and_set(&cld_cache_lock, 1))
		sched_yield();
}

static void cld_unlock_cache(void) {
	__sync_lock_release(&cld_cache_lock);
}

static void *cld_cache_get(const char *key) {
	void *handle = NULL;
	cld_lock_cache();
	for (size_t i = 0; i < CLD_CACHE_MAX; i++) {
		if (cld_cache[i].key && strcmp(cld_cache[i].key, key) == 0) {
			handle = cld_cache[i].handle;
			break;
		}
	}
	cld_unlock_cache();
	return handle;
}

static void cld_scan_providers(void) {
	// lock guards against concurrent first scans duplicating entries
	cld_lock_cache();
	if (cld_providers_scanned) {
		cld_unlock_cache();
		return;
	}
	cld_providers_scanned = 1;

	// Our own libc is the only meaningful provider of glibc symbols, find
	// its on-disk location through a symbol known to live in it and parse
	// that file so we get the same view of the version definitions as ld.so
	Dl_info info;
	void *sym = dlsym(RTLD_DEFAULT, "malloc");
	if (sym && dladdr(sym, &info) && info.dli_fname)
		cld_collect_versions_from_file(info.dli_fname);

	cld_unlock_cache();

	DEBUG_PRINT("cross-libc-dlopen: our libc provides %zu known versions\n", cld_provider_version_count);
}

static int cld_have_version(const char *name) {
	for (size_t i = 0; i < cld_provider_version_count; i++) {
		if (strcmp(cld_provider_versions[i], name) == 0)
			return 1;
	}
	return 0;
}

// ---------------------------------------------------------------------------
// Does the object that will satisfy `file` provide version `ver`?
//
// A DT_VERNEED record names a FILE and the versions wanted FROM it. Asking the
// question that way is both more precise and much cheaper than the flat set
// above, which only ever learned our libc's own names: every GLIBCXX_*,
// CXXABI_* and LLVM_* requirement was therefore unvouchable, so
// cld_requirements_satisfied() returned 0 for everything in a Mesa closure and
// objects that needed nothing got rewritten anyway. On a host whose glibc is
// OLDER than the bundled one, where by construction nothing CAN be missing,
// that turned a working driver into a rewritten one for no reason (issue #1).
//
// Resolution order matches the project's own rule that bundled beats host:
//   1. $APPDIR/lib/<file>, if the bundle owns that soname
//   2. whatever is already loaded under that soname
//   3. nothing, and then the answer is "no", which strips. Conservative is
//      the right direction: a needless rewrite is survivable, a missing
//      version is a hard load failure.
// ---------------------------------------------------------------------------
// Defined further down with the rest of the load path; declared here because
// "is this soname bundled" is the first question a provider lookup asks.
static int cld_bundled_dep_path(const char *soname, char *out, size_t outsz);

#define CLD_PROV_FILES 16
#define CLD_PROV_VERS  128
static struct cld_provider {
	char file[128];
	char *vers[CLD_PROV_VERS];
	size_t nvers;
	int resolved;                    // 1 once we have looked, even if empty
} cld_providers[CLD_PROV_FILES];
static size_t cld_provider_files;

// Collect DT_VERDEF names from `path` into `p`, ignoring the VER_FLG_BASE
// entry, which names the file rather than a version.
static int cld_provider_one(void *ctx, const char *name, ElfW(Half) ndx, int is_base) {
	struct cld_provider *p = ctx;
	(void)ndx;
	if (!is_base && p->nvers < CLD_PROV_VERS)
		p->vers[p->nvers++] = strdup(name);
	return 0;
}

static void cld_provider_load(struct cld_provider *p, const char *path) {
	struct cld_elf e;
	if (!cld_parse_elf(&e, path))
		return;
	cld_walk_verdefs(&e, cld_provider_one, p);
	cld_free_elf(&e);
}

// Its own lock, not the handle cache's: this one is held across a file read,
// and the handle cache is taken on every intercepted dlopen. With no lock at
// all, two threads can both pass the bounds check and both post-increment
// cld_provider_files, which writes one entry past the end of the table.
//
// Nothing under this lock can re-enter it. cld_provider_load only reads a file,
// and the dlopen below carries RTLD_NOLOAD, which our own hook declines before
// it touches any shared state.
static volatile int cld_provider_lock;

static void cld_lock_providers(void) {
	while (__sync_lock_test_and_set(&cld_provider_lock, 1))
		sched_yield();
}

static void cld_unlock_providers(void) {
	__sync_lock_release(&cld_provider_lock);
}

static struct cld_provider *cld_provider_for(const char *file) {
	const char *how = "not resolvable, treating as absent";
	struct cld_provider *p = NULL;
	char bundled[PATH_MAX];

	cld_lock_providers();

	for (size_t i = 0; i < cld_provider_files; i++) {
		if (strcmp(cld_providers[i].file, file) == 0) {
			p = &cld_providers[i];
			cld_unlock_providers();
			return p;                    // already answered, and answers never change
		}
	}
	if (cld_provider_files >= CLD_PROV_FILES) {
		cld_unlock_providers();
		return NULL;
	}

	p = &cld_providers[cld_provider_files++];
	snprintf(p->file, sizeof(p->file), "%s", file);
	p->resolved = 1;

	if (cld_bundled_dep_path(file, bundled, sizeof(bundled))) {
		cld_provider_load(p, bundled);
		how = bundled;
	} else {
		// RTLD_NOLOAD asks "is this already in the process", it never loads
		// anything, and our own dlopen hook declines NOLOAD, so this cannot
		// recurse back into the rewriting path.
		void *h = dlopen(file, RTLD_LAZY | RTLD_NOLOAD);
		if (h) {
			struct link_map *lm = NULL;
			if (dlinfo(h, RTLD_DI_LINKMAP, &lm) == 0 && lm && lm->l_name && *lm->l_name)
				cld_provider_load(p, lm->l_name);
			dlclose(h);
			how = "already loaded";
		}
	}

	size_t nvers = p->nvers;
	cld_unlock_providers();
	DEBUG_PRINT("cross-libc-dlopen: provider %s -> %s (%zu versions)\n", file, how, nvers);
	return p;
}

static int cld_file_provides(const char *file, const char *ver) {
	struct cld_provider *p = cld_provider_for(file);
	if (!p)
		return cld_have_version(ver);     // table full: fall back to the flat set
	for (size_t i = 0; i < p->nvers; i++)
		if (strcmp(p->vers[i], ver) == 0)
			return 1;
	// libc is special only in that we may know it under a different soname
	// than the verneed spells; the flat set covers that.
	return cld_have_version(ver);
}

// 1 when every version this object requires is provided by the object that
// will satisfy the file it names. Objects without version info (musl built)
// are trivially satisfied.
static int cld_requirements_satisfied(const struct cld_elf *e) {
	ElfW(Addr) verneed_vaddr = 0;
	if (!cld_dyn_find(e, DT_VERNEED, &verneed_vaddr))
		return 1;
	if (!e->strtab)
		return 0;

	size_t off = cld_vaddr_to_offset(e, verneed_vaddr);
	if (off == (size_t)-1)
		return 0;

	const char *base = e->map + off;
	size_t pos = 0;
	for (size_t guard = 0; guard < 4096; guard++) {
		if (pos + sizeof(ElfW(Verneed)) > e->size)
			return 0;
		const ElfW(Verneed) *vn = (const ElfW(Verneed) *)(base + pos);
		if (vn->vn_version != 1)
			return 0;

		// The file these versions are wanted FROM. Without it the question
		// degenerates into "does anything anywhere define this name", which
		// is what made every Mesa object look unsatisfiable.
		if (!cld_valid_cstr(e, vn->vn_file))
			return 0;
		const char *file = e->strtab + vn->vn_file;

		size_t apos = pos + vn->vn_aux;
		for (size_t aux_guard = 0; aux_guard < 4096; aux_guard++) {
			if (apos + sizeof(ElfW(Vernaux)) > e->size)
				return 0;
			const ElfW(Vernaux) *aux = (const ElfW(Vernaux) *)(base + apos);
			if (!cld_valid_cstr(e, aux->vna_name))
				return 0;
			if (!cld_file_provides(file, e->strtab + aux->vna_name)) {
				DEBUG_PRINT("cross-libc-dlopen: %s wants %s from %s, which does not have it\n",
				            "this object", e->strtab + aux->vna_name, file);
				return 0;
			}
			if (!aux->vna_next)
				break;
			apos += aux->vna_next;
		}

		if (!vn->vn_next)
			break;
		pos += vn->vn_next;
	}

	return 1;
}

// ---------------------------------------------------------------------------
// Which definition SHOULD an unversioned reference have reached?
//
// Stripping version tags, and being musl-built, which amounts to the same
// thing, turns every reference into a plain name lookup, and for the handful
// of symbols glibc still exports at an obsolete version that lookup does not
// pick the default one. src/version-compat.c closes that by defining those
// names itself and forwarding; this is how it learns what to forward TO.
//
// Answered from the defining file's own tables rather than from dlsym, because
// dlsym does not agree with itself across releases: measured in E27,
// dlsym(RTLD_NEXT, "pthread_cond_init") returns the OBSOLETE definition on
// glibc 2.31 and the default one on 2.41. The ELF says the same thing on both.
// ---------------------------------------------------------------------------

// {version index -> name} from DT_VERDEF, resolved for one index at a time so
// there is nothing to allocate.
struct cld_ndx_query { ElfW(Half) want; const char *found; };

static int cld_verdef_match(void *ctx, const char *name, ElfW(Half) ndx, int is_base) {
	struct cld_ndx_query *q = ctx;
	(void)is_base;
	if (ndx != q->want)
		return 0;
	q->found = name;
	return 1;
}

// The version NAME carried by version index `want`, or NULL.
static const char *cld_verdef_name(const struct cld_elf *e, ElfW(Half) want) {
	struct cld_ndx_query q = { want, NULL };
	cld_walk_verdefs(e, cld_verdef_match, &q);
	return q.found;
}

__attribute__((visibility("hidden")))
int cld_default_version_of(const char *sym, char *out, size_t outsz) {
	if (!sym || !out || outsz == 0)
		return 0;
	out[0] = '\0';

	// Any definition will do here; all we want from it is WHICH FILE defines
	// the name. On glibc 2.31 this deliberately-imperfect lookup returns the
	// obsolete definition, and that is fine: it lives in the same file.
	void *any = dlsym(RTLD_NEXT, sym);
	Dl_info info;
	if (!any || !dladdr(any, &info) || !info.dli_fname)
		return 0;

	struct cld_elf e;
	if (!cld_parse_elf(&e, info.dli_fname))
		return 0;

	int found = 0;
	ElfW(Addr) versym_vaddr = 0;
	size_t vs_off;
	if (!e.dynsym || !e.strtab ||
	    !cld_dyn_find(&e, DT_VERSYM, &versym_vaddr) ||
	    (vs_off = cld_vaddr_to_offset(&e, versym_vaddr)) == (size_t)-1 ||
	    vs_off + e.dynsym_num * sizeof(ElfW(Half)) > e.size)
		goto done;

	{
		const ElfW(Half) *versym = (const ElfW(Half) *)(e.map + vs_off);
		for (size_t i = 0; i < e.dynsym_num; i++) {
			if (e.dynsym[i].st_shndx == SHN_UNDEF)
				continue;
			if (!cld_valid_cstr(&e, e.dynsym[i].st_name))
				continue;
			if (strcmp(e.strtab + e.dynsym[i].st_name, sym) != 0)
				continue;
			// 0x8000 marks a NON-default (hidden) version. Skip those:
			// exactly one entry per name is the default.
			if (versym[i] & 0x8000)
				continue;
			ElfW(Half) ndx = versym[i] & 0x7fff;
			if (ndx <= 1)
				break;              // unversioned definition, nothing to name
			const char *name = cld_verdef_name(&e, ndx);
			if (name) {
				snprintf(out, outsz, "%s", name);
				found = 1;
			}
			break;
		}
	}

done:
	cld_free_elf(&e);
	return found;
}

// references become plain name lookups, every tag must go together or
// the orphaned remainder segfaults ld.so
static void cld_strip_versions(struct cld_elf *e) {
	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		if (e->dyn[i].d_tag == DT_VERSYM || e->dyn[i].d_tag == DT_VERNEED ||
		    e->dyn[i].d_tag == DT_VERDEF || e->dyn[i].d_tag == DT_VERDEFNUM)
			e->dyn[i].d_tag = CLD_NEUTRAL_TAG;
	}
}

// ---------------------------------------------------------------------------
// Undefined-symbol renaming (Design B)
//
// Some musl names differ from their glibc equivalent only cosmetically. musl's
// environ pointer is ___environ (three underscores), glibc's is __environ
// (two). The reference is a WEAK import, so it does not stop the load, and it
// silently resolves to 0 and the driver reads a NULL environment. Latent, and
// exactly the class of bug that "just works until it doesn't".
//
// The fix costs no string edits at all: "___environ" + 1 IS "__environ", so
// advancing st_name by one byte renames the reference. Two properties make
// this total rather than merely likely:
//
//   * the symbol is UNDEFINED, so DT_GNU_HASH does not index it (GNU hash
//     covers only defined symbols, from symoffset onward). No hash fixup.
//   * nothing is written to .dynstr, so .dynstr tail-merging, measured real at
//     16 of 647 names in libvulkan_lvp.so being suffixes of another, cannot
//     bite. We only move a pointer that already pointed into that string.
//
// The general case (rename X to Y where Y is NOT a suffix of X) needs an
// in-place .dynstr write, which tail-merging CAN break. cld_dynstr_write_safe()
// proves no other referenced offset falls inside the range before allowing it,
// and refuses when it cannot prove that. T0.7 checks that it does refuse.
// ---------------------------------------------------------------------------
struct cld_rename {
	const char *from;
	const char *to;
	const char *why;
};

static const struct cld_rename cld_renames[] = {
	{ "___environ", "__environ",
	  "musl spells the environ pointer with three underscores; glibc uses two" },
	{ NULL, NULL, NULL }
};

// Does `off` name a string that some OTHER part of the file still points at
// inside [lo, hi)? Used to refuse an unsafe in-place .dynstr write.
//
// Checks every offset that can reference .dynstr: symbol names, DT_NEEDED /
// SONAME / RPATH / RUNPATH, and the version tables' file and version names.
// Anything it cannot enumerate makes it answer "occupied", i.e. refuse.
static int cld_dynstr_range_occupied(const struct cld_elf *e, size_t lo, size_t hi,
                                     size_t exempt_off) {
	if (!e->strtab)
		return 1;

	for (size_t i = 0; i < e->dynsym_num; i++) {
		size_t off = (size_t)e->dynsym[i].st_name;
		if (off == exempt_off || !off)
			continue;
		if (off >= lo && off < hi)
			return 1;
	}

	for (size_t i = 0; i < e->dyn_num && e->dyn[i].d_tag != DT_NULL; i++) {
		ElfW(Sxword) t = e->dyn[i].d_tag;
		if (t != DT_NEEDED && t != DT_SONAME && t != DT_RPATH && t != DT_RUNPATH)
			continue;
		size_t off = (size_t)e->dyn[i].d_un.d_val;
		if (off >= lo && off < hi)
			return 1;
	}

	// Version tables. If either is present but unreadable we refuse rather
	// than assume it holds nothing in range.
	ElfW(Addr) vn_vaddr = 0;
	if (cld_dyn_find(e, DT_VERNEED, &vn_vaddr)) {
		size_t base = cld_vaddr_to_offset(e, vn_vaddr);
		if (base == (size_t)-1)
			return 1;
		size_t pos = 0;
		for (size_t guard = 0; guard < 4096; guard++) {
			if (base + pos + sizeof(ElfW(Verneed)) > e->size)
				return 1;
			const ElfW(Verneed) *vn = (const ElfW(Verneed) *)(e->map + base + pos);
			if (vn->vn_file >= lo && vn->vn_file < hi)
				return 1;
			size_t apos = pos + vn->vn_aux;
			for (size_t ag = 0; ag < 4096; ag++) {
				if (base + apos + sizeof(ElfW(Vernaux)) > e->size)
					return 1;
				const ElfW(Vernaux) *aux = (const ElfW(Vernaux) *)(e->map + base + apos);
				if (aux->vna_name >= lo && aux->vna_name < hi)
					return 1;
				if (!aux->vna_next)
					break;
				apos += aux->vna_next;
			}
			if (!vn->vn_next)
				break;
			pos += vn->vn_next;
		}
	}

	ElfW(Addr) vd_vaddr = 0;
	if (cld_dyn_find(e, DT_VERDEF, &vd_vaddr)) {
		size_t base = cld_vaddr_to_offset(e, vd_vaddr);
		if (base == (size_t)-1)
			return 1;
		size_t pos = 0;
		for (size_t guard = 0; guard < 4096; guard++) {
			if (base + pos + sizeof(ElfW(Verdef)) > e->size)
				return 1;
			const ElfW(Verdef) *vd = (const ElfW(Verdef) *)(e->map + base + pos);
			size_t apos = pos + vd->vd_aux;
			for (size_t ag = 0; ag < vd->vd_cnt && ag < 4096; ag++) {
				if (base + apos + sizeof(ElfW(Verdaux)) > e->size)
					return 1;
				const ElfW(Verdaux) *aux = (const ElfW(Verdaux) *)(e->map + base + apos);
				if (aux->vda_name >= lo && aux->vda_name < hi)
					return 1;
				if (!aux->vda_next)
					break;
				apos += aux->vda_next;
			}
			if (!vd->vd_next)
				break;
			pos += vd->vd_next;
		}
	}

	return 0;
}

// Rename one undefined symbol. Returns 1 when the rename happened.
//
// Only two routes are allowed, and only the first is ever needed in practice:
//
//   suffix   `to` is a suffix of `from` -> bump st_name. No write at all.
//   in-place `to` is no longer than `from` -> overwrite the bytes, but only
//            after proving nothing else points inside the range (T0.7).
static int cld_rename_undef_symbol(struct cld_elf *e, const struct cld_rename *r,
                                   int dry_run) {
	if (!e->dynsym || !e->strtab)
		return 0;

	size_t flen = strlen(r->from), tlen = strlen(r->to);
	if (tlen > flen)
		return 0;                        // would need to grow .dynstr

	int done = 0;
	for (size_t i = 0; i < e->dynsym_num; i++) {
		ElfW(Sym) *s = &e->dynsym[i];
		if (s->st_shndx != SHN_UNDEF || !s->st_name)
			continue;
		size_t off = (size_t)s->st_name;
		if (!cld_valid_cstr(e, off))
			continue;
		if (strcmp(e->strtab + off, r->from) != 0)
			continue;

		// Defined symbols are indexed by DT_GNU_HASH; renaming one without
		// rebuilding the chains corrupts lookup. Undefined symbols live below
		// symoffset and are not hashed. Belt and braces: check the index too.
		if (e->gnu_symoffset && i >= e->gnu_symoffset) {
			DEBUG_PRINT("cross-libc-dlopen: refusing to rename %s at index %zu: "
			            "inside the DT_GNU_HASH region (symoffset %zu)\n",
			            r->from, i, e->gnu_symoffset);
			continue;
		}

		if (strcmp(e->strtab + off + (flen - tlen), r->to) == 0) {
			// suffix identity: no bytes change, only where we point
			if (!dry_run)
				s->st_name = (ElfW(Word))(off + (flen - tlen));
			DEBUG_PRINT("cross-libc-dlopen: %s -> %s (st_name +%zu, no .dynstr write)\n",
			            r->from, r->to, flen - tlen);
			done = 1;
			continue;
		}

		// General case. Clobbering [off, off+flen] breaks any other name that
		// is a suffix of this one, and tail-merging makes that a live hazard,
		// not a theoretical one. Prove it is safe or decline.
		if (cld_dynstr_range_occupied(e, off + 1, off + flen + 1, off)) {
			DEBUG_PRINT("cross-libc-dlopen: refusing in-place rename %s -> %s: another "
			            ".dynstr reference falls inside the range "
			            "(tail-merged strings)\n", r->from, r->to);
			continue;
		}
		if (!dry_run) {
			char *w = (char *)e->strtab + off;
			memcpy(w, r->to, tlen + 1);
		}
		DEBUG_PRINT("cross-libc-dlopen: %s -> %s (in-place .dynstr write, %zu bytes)\n",
		            r->from, r->to, tlen + 1);
		done = 1;
	}
	return done;
}

static int cld_apply_renames(struct cld_elf *e, int dry_run) {
	// Escape hatch: renaming is the one rewrite that changes SEMANTICS rather
	// than just relaxing a check, so it needs to be switchable when bisecting
	// a misbehaving driver. CROSS_LIBC_DLOPEN_NORENAME=1 turns it off.
	const char *off = cld_getenv("CROSS_LIBC_DLOPEN_NORENAME", NULL);
	if (off && strcmp(off, "1") == 0) {
		DEBUG_PRINT("cross-libc-dlopen: symbol renaming disabled by "
		            "CROSS_LIBC_DLOPEN_NORENAME=1\n");
		return 0;
	}

	int n = 0;
	for (size_t i = 0; cld_renames[i].from; i++)
		n += cld_rename_undef_symbol(e, &cld_renames[i], dry_run);
	return n;
}

// load chain of the cross-libc dlopen currently in progress, used both to
// cut off cycles and to know which directories a refused dependency may
// still be hiding in. Thread local, every thread walks its own chain
static __thread const char *cld_active_stack[16];

// When the linker refuses a dependency over symbol versions the error
// names both the refusing file and who wanted it, e.g.:
//
//   /usr/lib/libLLVM.so: version `GLIBC_2.38' not found (required by ./foo_dri.so)
//
// The one that needs rewriting is the required-by side, harvest its path.
// NULL for every other failure kind, those have nothing to recover
static char *cld_path_from_dlerror(void) {
	char *err = dlerror();
	if (!err)
		return NULL;

	const char *marker = strstr(err, "(required by ");
	if (!marker)
		return NULL;
	marker += strlen("(required by ");

	const char *end = strchr(marker, ')');
	if (!end || end == marker)
		return NULL;

	// only trust absolute paths, relative ones depend on caller cwd
	if (*marker != '/')
		return NULL;

	return strndup(marker, (size_t)(end - marker));
}

// Fallback hunt next to the current load chain
static char *cld_find_candidate(const char *name, int depth) {
	char path[PATH_MAX * 2];
	const char *dirs[2 * sizeof(cld_active_stack) / sizeof(*cld_active_stack)] = { NULL };
	size_t dir_count = 0;

	for (int i = 0; i <= depth && i < (int)(sizeof(cld_active_stack) / sizeof(*cld_active_stack)); i++) {
		const char *slash = strrchr(cld_active_stack[i], '/');
		if (!slash || slash == cld_active_stack[i] || dir_count + 1 >= sizeof(dirs) / sizeof(*dirs))
			continue;
		// dedupe is not worth the effort, access() misses are cheap
		dirs[dir_count++] = strndupa(cld_active_stack[i], slash - cld_active_stack[i]);
	}

	for (size_t i = 0; i < dir_count; i++) {
		snprintf(path, sizeof(path), "%s/%s", dirs[i], name);
		if (access(path, R_OK) == 0)
			return strdup(path);
	}

	return NULL;
}

// rewritten images land as real files (so realpath() works on them) under
// a content-derived name, meaning repeated runs overwrite instead of
// filling up the runtime dir
#define CLD_TMP_PREFIX ".cross-libc-dlopen-"

static unsigned cld_content_hash(const char *s, size_t extra) {
	unsigned h = 2166136261u;
	while (*s) {
		h ^= (unsigned char)*s++;
		h *= 16777619u;
	}
	h ^= (unsigned)extra;
	h *= 16777619u;
	return h;
}

static char *cld_emit_copy(const char *buf, size_t len, const char *key) {
	int fd = -1;
	char dir[PATH_MAX];
	const char *tmp = getenv("XDG_RUNTIME_DIR");

	if (!tmp || !*tmp)
		tmp = getenv("TMPDIR");
	if (!tmp || !*tmp)
		tmp = "/tmp";
	snprintf(dir, sizeof(dir), "%s", tmp);

	char final[PATH_MAX * 2];
	snprintf(final, sizeof(final), "%s/" CLD_TMP_PREFIX "%08x.so", dir, cld_content_hash(key, len));
	unlink(final);

	// preferred: invisible tmpfile linked into place, self-cleans on crash
	// and survives as a normal file so realpath() works on it
	fd = open(dir, O_TMPFILE | O_WRONLY, 0600);
	if (fd >= 0) {
		size_t done = 0;
		while (done < len) {
			ssize_t n = write(fd, buf + done, len - done);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;
			done += (size_t)n;
		}
		if (done == len) {
			int dirfd = open(dir, O_RDONLY | O_DIRECTORY);
			if (dirfd >= 0 && linkat(fd, "", dirfd, strrchr(final, '/') + 1, AT_EMPTY_PATH) == 0) {
				close(dirfd);
				close(fd);
				return strdup(final);
			}
			if (dirfd >= 0)
				close(dirfd);
		}
		close(fd);
	}

	// fallback for filesystems/kernels without O_TMPFILE support, the
	// renamed result intentionally stays so realpath() keeps working
	char *template = malloc(strlen(final) + 8);
	if (!template)
		return NULL;
	strcpy(template, final);
	strcat(template, "XXXXXX");
	fd = mkstemp(template);
	if (fd < 0) {
		free(template);
		return NULL;
	}

	size_t done = 0;
	while (done < len) {
		ssize_t n = write(fd, buf + done, len - done);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			close(fd);
			free(template);
			return NULL;
		}
		done += (size_t)n;
	}
	close(fd);

	// atomically place it under the deterministic name
	if (rename(template, final) != 0) {
		unlink(template);
		free(template);
		return NULL;
	}
	free(template);
	return strdup(final);
}

static void cld_cache_put(const char *key, void *handle) {
	cld_lock_cache();
	for (size_t i = 0; i < CLD_CACHE_MAX; i++) {
		if (!cld_cache[i].key) {
			cld_cache[i].key = strdup(key);
			cld_cache[i].handle = handle;
			break;
		}
	}
	cld_unlock_cache();
}

// ---------------------------------------------------------------------------
// Unresolved-symbol reporting (Design B, dry-run mode)
//
// Every Mesa object is DF_BIND_NOW, so ld.so resolves the whole symbol table
// at load: one missing symbol makes the library unloadable and the error names
// only the FIRST one. Walking the imports ourselves and testing each against
// the process's own lookup scope reports ALL of them at once, and does it
// without loading anything, which is what makes this testable with no GPU
// and no Alpine.
//
// This is the generalisable half of the gconv lesson: a plugin
// subsystem that fails loudly with the symbol named is debuggable; one that
// "just randomly breaks" is not.
#define CLD_REPORT_MAX 24
#define CLD_DEPS_MAX   64

// Handles of the DT_NEEDED closure we loaded for the object under
// consideration. An object's imports are satisfied by its own dependencies,
// not only by the process's global scope, so a report that consults only
// RTLD_DEFAULT accuses the object of missing symbols its siblings provide.
// Measured: without this, loading libvulkan_lvp.so "reported" 446 missing
// symbols (LLVMBuildAdd, drmIoctl, xcb_*), every one of which its own
// DT_NEEDED closure supplies. The diagnostic was louder than the bug.
#define CLD_UNOPENED_MAX 8
struct cld_deps {
	void *h[CLD_DEPS_MAX];
	size_t n;
	// DT_NEEDED entries that could not be opened at all. Recorded because a
	// dependency that failed to load makes ALL of its symbols look unresolved,
	// and the report then blames the bundled glibc for a couple of hundred
	// LLVM symbols it never had anything to do with (issue #1).
	char unopened[CLD_UNOPENED_MAX][64];
	size_t n_unopened;
};

static void cld_note_unopened(struct cld_deps *deps, const char *soname) {
	if (!deps || deps->n_unopened >= CLD_UNOPENED_MAX)
		return;
	snprintf(deps->unopened[deps->n_unopened], sizeof(deps->unopened[0]), "%s", soname);
	deps->n_unopened++;
}

static int cld_resolvable(const char *name, const struct cld_deps *deps) {
	// RTLD_DEFAULT walks the global scope, which includes this preload's own
	// exports, which is how the shim satisfies imports (E2, E5).
	//
	// NB: no dlerror() call anywhere in here. dlerror() is destructive, and
	// the caller of the intercepted dlopen() needs the real message intact.
	if (dlsym(RTLD_DEFAULT, name))
		return 1;
	if (deps)
		for (size_t i = 0; i < deps->n; i++)
			if (deps->h[i] && dlsym(deps->h[i], name))
				return 1;
	return 0;
}

static int cld_report_unresolved(const struct cld_elf *e, const char *what,
                                 const struct cld_deps *deps, int always) {
	if (!e->dynsym || !e->strtab)
		return -1;

	int missing = 0;
	int libc_shaped = 0;              // any unresolved name a libc could plausibly own
	char names[CLD_REPORT_MAX][128];

	for (size_t i = 0; i < e->dynsym_num; i++) {
		const ElfW(Sym) *s = &e->dynsym[i];
		if (s->st_shndx != SHN_UNDEF || !s->st_name)
			continue;
		// ELF32_ST_BIND and ELF64_ST_BIND are the same shift; spelling it
		// out avoids depending on which of the two link.h picked.
		unsigned char bind = (unsigned char)(s->st_info >> 4);
		if (bind != STB_GLOBAL)
			continue;                    // weak resolves to 0, never fatal
		if (!cld_valid_cstr(e, (size_t)s->st_name))
			continue;
		const char *name = e->strtab + s->st_name;
		if (!*name)
			continue;

		if (cld_resolvable(name, deps))
			continue;

		if (missing < CLD_REPORT_MAX) {
			snprintf(names[missing], sizeof(names[0]), "%s", name);
		}
		// A C++ mangled name or an LLVM_* entry point is never something a
		// libc provides, so a set made only of those cannot be explained by
		// the bundled glibc being old.
		if (strncmp(name, "_Z", 2) != 0 && strncmp(name, "LLVM", 4) != 0)
			libc_shaped = 1;
		missing++;
	}

	if (missing && always) {
		fprintf(stderr,
		        "\n [cross-libc-dlopen.so] >> %s needs %d symbol%s nothing in this process\n"
		        " [cross-libc-dlopen.so] >> nor its own dependency closure provides:\n",
		        what, missing, missing == 1 ? "" : "s");
		for (int i = 0; i < missing && i < CLD_REPORT_MAX; i++)
			fprintf(stderr, " [cross-libc-dlopen.so] >>     %s\n", names[i]);
		if (missing > CLD_REPORT_MAX)
			fprintf(stderr, " [cross-libc-dlopen.so] >>     ... and %d more\n",
			        missing - CLD_REPORT_MAX);
		// Say what is actually KNOWN before offering a guess. A dependency
		// that failed to open explains every symbol it would have provided,
		// and blaming the bundled glibc instead sends the reader to
		// CROSS_LIBC_DLOPEN_RUNTIME=host, which cannot help and costs an afternoon.
		if (deps && deps->n_unopened) {
			fprintf(stderr,
			        " [cross-libc-dlopen.so] >> %zu of this object's own dependencies could not be "
			        "opened:\n", deps->n_unopened);
			for (size_t i = 0; i < deps->n_unopened; i++)
				fprintf(stderr, " [cross-libc-dlopen.so] >>     %s\n", deps->unopened[i]);
			fprintf(stderr,
			        " [cross-libc-dlopen.so] >> The symbols above are most likely theirs, not the "
			        "bundled libc's.\n"
			        " [cross-libc-dlopen.so] >> Give the loader a path to them: distros that keep "
			        "LLVM outside the\n"
			        " [cross-libc-dlopen.so] >> standard libdirs (Gentoo /usr/lib/llvm/N/lib64, "
			        "Debian /usr/lib/llvm-N/lib)\n"
			        " [cross-libc-dlopen.so] >> reach them only through /etc/ld.so.cache, which a "
			        "bundled ld.so does\n"
			        " [cross-libc-dlopen.so] >> not read. SHARUN_EXTRA_LIBRARY_PATH is the usual "
			        "way out.\n\n");
		} else if (libc_shaped) {
			fprintf(stderr,
			        " [cross-libc-dlopen.so] >> Most likely the bundled glibc predates them. "
			        "CROSS_LIBC_DLOPEN_RUNTIME=host\n"
			        " [cross-libc-dlopen.so] >> runs against the host's own libc, which will have them.\n\n");
		} else {
			fprintf(stderr,
			        " [cross-libc-dlopen.so] >> Not one of these is a C symbol any libc exports, so "
			        "the bundled\n"
			        " [cross-libc-dlopen.so] >> glibc is not the problem and CROSS_LIBC_DLOPEN_RUNTIME=host "
			        "will not help.\n"
			        " [cross-libc-dlopen.so] >> Something this object links against is missing from "
			        "the search path.\n\n");
		}
	} else if (missing) {
		DEBUG_PRINT("%s: %d unresolvable symbol(s), first is %s\n",
		            what, missing, missing ? names[0] : "?");
	} else {
		DEBUG_PRINT("%s: every strong import resolvable\n", what);
	}
	return missing;
}

static int cld_dryrun_enabled(void) {
	const char *v = cld_getenv("CROSS_LIBC_DLOPEN_DRYRUN", NULL);
	return v && strcmp(v, "1") == 0;
}

// ---------------------------------------------------------------------------
// Keep the whole glibc family in the GLOBAL scope (Design B, global-scope libraries)
//
// Stripping a version tag turns a reference into a plain name lookup. That
// only works if the name is visible in the process's global scope, and a
// symbol can sit in a DIFFERENT library on the guest's libc than on ours.
// Two independent re-homings bite, and both are measured:
//
//  1. glibc 2.34 merged libpthread/libdl/librt/libutil/libanl into libc.so.6.
//     A modern build emits pthread_create@GLIBC_2.34 with NO DT_NEEDED on
//     libpthread. On a pre-2.34 bundled runtime that symbol lives only in
//     libpthread.so.0, so the stripped lookup succeeds if and only if that
//     library is already loaded (E7) and fails if it is not (E6).
//
//  2. musl puts libm, libpthread, libdl, librt and the resolver INSIDE its
//     libc; glibc splits them out. A musl-built object therefore imports
//     fmod, fesetround, log10, pow with no DT_NEEDED on anything, because on
//     musl its libc edge covered them, and that edge is exactly the one we
//     drop. Measured on Alpine v3.22: libxml2 failed on `fmod` and libstdc++
//     on `fesetround`, which cascaded into libLLVM and took the whole ICD
//     down. libm.so.6 was simply not in the process.
//
// Both are the same bug shape and both are fixed by making sure every glibc
// library that could hold a re-homed name is loaded RTLD_GLOBAL up front.
// Nothing else guarantees it: the app's own binaries may have no reason to
// pull libm in.
//
// This is rung 6 of the diagnostic ladder applied as a policy rather
// than per incident: load the library instead of shimming the symbol.
static const char *cld_global_scope_libs[] = {
	// musl folds these into libc.so; glibc splits them out
	"libm.so.6",
	"libresolv.so.2",
	"libcrypt.so.1",
	// glibc's own pre-2.34 split libraries (E6/E7)
	"libpthread.so.0",
	"libdl.so.2",
	"librt.so.1",
	"libutil.so.1",
	"libanl.so.1",
	NULL
};

__attribute__((constructor))
static void cld_load_global_scope_libs(void) {
	// Idempotent, because it is also reachable from cross_libc_dlopen_init_now()
	// below: another preload that has to load a host object may need this set
	// present before its own constructor runs, and preload constructors run in
	// REVERSE of the .preload order (E56), so "listed after us" means "runs
	// before us". Doing it twice would be harmless but noisy in a trace.
	static int done;
	if (done)
		return;
	done = 1;

	if (!cross_libc_dlopen_mode())
		return;

	const char *appdir = cld_root();
	char path[PATH_MAX];

	for (size_t i = 0; cld_global_scope_libs[i]; i++) {
		const char *name = cld_global_scope_libs[i];

		// Prefer the bundled copy: it is guaranteed to match the bundled
		// libc, and a host copy from a different glibc is precisely the
		// mixed set that segfaults (E11).
		void *h = NULL;
		if (appdir && *appdir) {
			snprintf(path, sizeof(path), "%s/%s/%s", appdir, cld_libdir(), name);
			if (access(path, R_OK) == 0)
				h = dlopen(path, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
		}
		if (!h)
			h = dlopen(name, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);

		DEBUG_PRINT("global-scope lib %s: %s\n", name, h ? "loaded" : "absent");
	}
}

// Bring this preload fully up before the caller does something that depends on
// it. The only caller is another preload, gl-fwd.so, whose constructor
// dlopens a HOST library, and a host object with its musl libc edge dropped
// needs the bundled libc runtime set already in the global scope. Preload
// constructors run in reverse of the .preload order (E56), so no ordering of
// that file puts this one first for every consumer, and an ordering rule that
// depends on undocumented loader behaviour is not a rule worth having.
//
// Safe to call from anywhere and any number of times.
VISIBLE void cross_libc_dlopen_init_now(void) {
	cld_load_global_scope_libs();
}

// ---------------------------------------------------------------------------
// libva's driver search list (LIBVA_DRIVERS_PATH)
//
// libva never dlopens its driver by soname. va_openDriver() walks a search
// list and dlopens the ABSOLUTE path it constructs from each entry,
// <dir>/<name>_drv_video.so. The list is LIBVA_DRIVERS_PATH, or the
// VA_DRIVERS_PATH compiled into the libva being run. That compiled default
// names the layout of whatever distro BUILT that libva, and a bundled
// libva therefore carries its build host's answer into a process running
// on a different one. No library path can correct this, because no soname
// lookup happens; the list is ours to assemble, the same act sharun
// performs for ld.so.
//
// Why only when libva is loaded: the variable is libva's, and a process
// that never loads libva gets nothing written into its environment. The
// check is dl_iterate_phdr, once from the constructor (libva linked at
// startup) and once after every successful dlopen until it fires (libva
// dlopened late, as gstreamer loads its va plugin). Either route has fired
// before vaInitialize can read the variable: a dlopen of libva itself is
// the last load that can precede that read, and the check runs after that
// very dlopen returns.
//
// Nothing here opens a library (conventions/code.md): appending directories
// to a search list is not searching it, and libva does its own searching
// from the result. The bundle's own lib/dri is deliberately never included:
// a bundle that ships VA drivers manages LIBVA_DRIVERS_PATH itself, and
// whatever it set already sits ahead of anything appended here.
//
// The existing value keeps priority and is never clobbered: anything this
// assembles goes at the END, the same place the conventions put appended
// library-path entries, so a user's or a launcher's choice always wins.
#define CLD_VA_LIBVA_SONAME "libva.so."
#define CLD_VA_DRIVERS_PATH "LIBVA_DRIVERS_PATH"

#if defined(__x86_64__)
#  define CLD_TRIPLET "x86_64-linux-gnu"
#elif defined(__aarch64__)
#  define CLD_TRIPLET "aarch64-linux-gnu"
#elif defined(__i386__)
#  define CLD_TRIPLET "i386-linux-gnu"
#else
#  define CLD_TRIPLET "unknown"
#endif

// The conventional libdirs of the hosts this runs on, each probed as
// <dir>/dri. Debian and Ubuntu keep their VA drivers under the triplet
// directory, Alpine in /usr/lib/dri, Fedora in /usr/lib64/dri. A missed
// access() costs nothing.
static const char *const cld_va_libdirs[] = {
	"/usr/lib/" CLD_TRIPLET, "/lib/" CLD_TRIPLET,
	"/usr/lib64", "/lib64",
	"/usr/lib", "/lib",
	"/usr/local/lib", "/usr/local/lib64",
	NULL
};

static int cld_va_phdr_cb(struct dl_phdr_info *info, size_t size, void *data) {
	(void)size;
	const char *name = info->dlpi_name;
	const char *base = strrchr(name, '/');
	base = base ? base + 1 : name;
	if (strncmp(base, CLD_VA_LIBVA_SONAME,
	            sizeof(CLD_VA_LIBVA_SONAME) - 1) == 0) {
		*(int *)data = 1;
		return 1;
	}
	return 0;
}

static int cld_va_libva_loaded(void) {
	// dlpi_name is the soname for DT_NEEDED libraries and a path for
	// dlopened ones, so the basename is what has to match either way
	int found = 0;
	dl_iterate_phdr(cld_va_phdr_cb, &found);
	return found;
}

struct cld_va_list {
	char buf[4096];
	size_t used;
};

static int cld_va_has(const struct cld_va_list *l, const char *dir) {
	size_t len = strlen(dir);
	const char *p = l->buf;
	while (*p) {
		const char *end = strchr(p, ':');
		if (!end) end = p + strlen(p);
		if ((size_t)(end - p) == len && strncmp(p, dir, len) == 0)
			return 1;
		p = *end ? end + 1 : end;
	}
	return 0;
}

static void cld_va_add(struct cld_va_list *l, const char *dir) {
	char path[PATH_MAX];
	int n = snprintf(path, sizeof(path), "%s/dri", dir);
	if (n < 0 || n >= (int)sizeof(path))
		return;
	if (access(path, X_OK) != 0)
		return;
	if (cld_va_has(l, path))
		return;
	int w = snprintf(l->buf + l->used, sizeof(l->buf) - l->used,
	                 "%s%s", l->used ? ":" : "", path);
	if (w < 0 || (size_t)w >= sizeof(l->buf) - l->used) {
		DEBUG_PRINT("LIBVA_DRIVERS_PATH is full; %s omitted\n", path);
		return;
	}
	l->used += (size_t)w;
}

// One guarded run. ⛔ The guard means "settled", not "ran": a constructor
// that latched on "libva absent" would disarm the post-dlopen scan for the
// process's whole life, and the late-load case would never fire. Measured
// here as E97, which went exactly that way on the first revision. So the
// scan re-runs after every successful dlopen until libva is found; before
// that, each pass costs one phdr walk per dlopen, and a dlopen is already
// the more expensive of the two.
static int cld_va_done;

static void cld_va_setup(void) {
	if (cld_va_done)
		return;

	if (!cross_libc_dlopen_mode()) {
		cld_va_done = 1;
		return;
	}

	// Not loaded yet is NOT settled: the next dlopen may bring libva in.
	if (!cld_va_libva_loaded()) {
		DEBUG_PRINT("LIBVA_DRIVERS_PATH: libva not loaded, untouched\n");
		return;
	}
	cld_va_done = 1;

	struct cld_va_list l = { { 0 }, 0 };

	// The value already set, the user's or the launcher's, keeps its
	// place at the front of libva's walk.
	const char *cur = getenv(CLD_VA_DRIVERS_PATH);
	if (cur && *cur) {
		int w = snprintf(l.buf, sizeof(l.buf), "%s", cur);
		if (w < 0 || (size_t)w >= sizeof(l.buf)) {
			DEBUG_PRINT("LIBVA_DRIVERS_PATH already overlong, left alone\n");
			return;
		}
		l.used = (size_t)w;
	}

	// The process's own search list first: a launcher that already
	// assembled the host library path (sharun) has written the host's
	// answers there, and <libdir>/dri is where those answers keep VA.
	const char *lp = getenv("LD_LIBRARY_PATH");
	if (lp && *lp) {
		char *copy = strdup(lp);
		if (copy) {
			for (char *p = strtok(copy, ":"); p; p = strtok(NULL, ":"))
				if (is_host_library_path(p))
					cld_va_add(&l, p);
			free(copy);
		}
	}

	for (size_t i = 0; cld_va_libdirs[i]; i++)
		cld_va_add(&l, cld_va_libdirs[i]);

	if (!l.used) {
		DEBUG_PRINT("LIBVA_DRIVERS_PATH: libva loaded, no host dri "
		            "directory found, untouched\n");
		return;
	}

	if (cld_dryrun_enabled()) {
		fprintf(stderr,
		        " [cross-libc-dlopen.so] >> DRYRUN LIBVA_DRIVERS_PATH "
		        "would be: %s\n", l.buf);
		return;
	}

	if (setenv(CLD_VA_DRIVERS_PATH, l.buf, 1) != 0) {
		DEBUG_PRINT("LIBVA_DRIVERS_PATH setenv failed: %s\n",
		            strerror(errno));
		return;
	}
	DEBUG_PRINT("LIBVA_DRIVERS_PATH=%s\n", l.buf);
}

__attribute__((constructor))
static void cld_va_init(void) {
	cld_va_setup();
}

// core libraries are never stripped nor loaded twice, rewriting the
// dynamic linker or libc is a one way ticket to segfault city. ld-linux
// carries no soname so RTLD_NOLOAD cannot catch it, hence this list
static const char *cld_never_touch[] = {
	"ld-linux",
	"ld-musl",
	"libc.so.",
	"libc.musl",
	"libm.so.",
	"libm.musl",
	"libpthread.so.",
	"libpthread.musl",
	"libdl.so.",
	"librt.so.",
	NULL
};

// musl objects demand their own libc through sonames like
// libc.musl-x86_64.so.1, a second libc may never enter the process, so
// these dependencies get dropped and every import binds to ours by name
static int cld_is_musl_libc(const char *name) {
	return strstr(name, ".musl") != NULL || strstr(name, "ld-musl") != NULL;
}

static int cld_is_core_library(const char *path) {
	const char *basename = strrchr(path, '/');
	basename = basename ? basename + 1 : path;

	for (size_t i = 0; cld_never_touch[i]; i++) {
		if (strncmp(basename, cld_never_touch[i], strlen(cld_never_touch[i])) == 0)
			return 1;
	}
	return 0;
}

// Does the AppDir bundle a library with this soname? Fills `out` and returns 1.
//
// Only $APPDIR/lib is consulted, which is where sharun's lib4bin puts the
// collected closure. Anything reachable only through a lib.path subdirectory
// is deliberately not searched here: this is a "does the bundle already own
// this soname" question, not a second library-search implementation (Design P).
static int cld_bundled_dep_path(const char *soname, char *out, size_t outsz) {
	const char *appdir = cld_root();
	if (!appdir || !*appdir || !soname || !*soname)
		return 0;
	if (strchr(soname, '/'))
		return 0;                        // a path, not a soname
	snprintf(out, outsz, "%s/%s/%s", appdir, cld_libdir(), soname);
	return access(out, R_OK) == 0;
}

static void *cld_load(dlopen_func_t dlopen_orig, const char *canon, int flags, int depth) {
	if (depth >= (int)(sizeof(cld_active_stack) / sizeof(*cld_active_stack))) {
		DEBUG_PRINT("cross-libc-dlopen: %s nested too deep, giving up\n", canon);
		return NULL;
	}

	void *cached = cld_cache_get(canon);
	if (cached)
		return cached;

	// fast path for anything the process already has loaded, this also
	// keeps our hands off libc, the dynamic linker itself and every
	// bundled library, none of those may ever be rewritten
	void *already_loaded = dlopen_orig(canon, flags | RTLD_NOLOAD);
	if (already_loaded)
		return already_loaded;

	// libc, the dynamic linker and friends are off limits no matter what
	if (cld_is_core_library(canon))
		return dlopen_orig(canon, flags);

	for (int i = 0; i < depth; i++) {
		if (strcmp(cld_active_stack[i], canon) == 0) {
			DEBUG_PRINT("cross-libc-dlopen: dependency cycle at %s\n", canon);
			return NULL;
		}
	}
	cld_active_stack[depth] = canon;

	struct cld_elf e;
	if (!cld_parse_elf(&e, canon)) {
		DEBUG_PRINT("cross-libc-dlopen: could not parse %s\n", canon);
		return dlopen_orig(canon, flags);
	}

	int has_tags = cld_has_version_tags(&e);
	// The satisfaction check is deliberately NOT run here. It asks whether
	// the object that will satisfy each DT_VERNEED file provides the versions
	// wanted from it, and half those files are this object's own dependencies,
	// which have not been loaded yet. Asking now would answer "absent" for
	// every one of them and strip unconditionally. It runs after the closure
	// walk below instead.

	// pre-pass: classify the dependency edges. musl flavored objects
	// demand musl libc, which gets dropped so nothing poisons the process
	int musl_guest = 0;
	size_t drop_idx[64];
	size_t drop_count = 0;
	for (size_t i = 0; i < e.dyn_num && e.dyn[i].d_tag != DT_NULL; i++) {
		if (e.dyn[i].d_tag != DT_NEEDED || !e.strtab)
			continue;
		ElfW(Word) off = (ElfW(Word))e.dyn[i].d_un.d_val;
		if (!cld_valid_cstr(&e, off) || !*(&e.strtab[off]))
			continue;
		if (cld_is_musl_libc(e.strtab + off)) {
			musl_guest = 1;
			if (drop_count < sizeof(drop_idx) / sizeof(*drop_idx))
				drop_idx[drop_count++] = i;
		}
	}
	int needs_strip = 0;
	struct cld_deps deps = { 0 };   /* {0}: a field added later cannot be left uninitialised */

	// closure first, even a satisfiable parent may pull in children
	// that need stripping. The linker resolves glibc world dependencies
	// wherever they live, only a refusal sends us hunting for the file.
	// musl guests skip probing entirely, loading any of their closures
	// unstripped would drag musl libc into the process
	for (size_t i = 0; i < e.dyn_num && e.dyn[i].d_tag != DT_NULL; i++) {
		if (e.dyn[i].d_tag != DT_NEEDED || !e.strtab)
			continue;
		ElfW(Word) off = (ElfW(Word))e.dyn[i].d_un.d_val;
		if (!cld_valid_cstr(&e, off) || !*(&e.strtab[off]))
			continue;
		const char *dep = e.strtab + off;

		if (cld_is_core_library(dep))
			continue;

		// T4.2: bundled libraries must beat host libraries.
		//
		// This has to happen BEFORE the host hunt, and it has to happen for
		// musl guests too. Upstream skipped the probe entirely for musl
		// guests, correctly refusing to load the HOST copy unstripped,
		// since that would drag musl libc in. But the skip sent them
		// straight to cld_find_candidate(), which only searches directories
		// on the active load stack. For a host object that is /usr/lib, so a
		// bundled soname could never win.
		//
		// Measured on Alpine: the AppDir bundles libstdc++.so.6.0.36 and
		// libgcc_s.so.1, yet the host's libstdc++.so.6.0.33 and libgcc_s were
		// loaded alongside them. Two libstdc++ and two unwinders in one
		// process is the classic "every symbol resolves and nothing works"
		// configuration, and it is exactly what T4.2 exists to catch.
		//
		// Loading the bundled copy is always safe: it is a glibc object built
		// against the runtime we are already running.
		char bundled[PATH_MAX];
		if (cld_bundled_dep_path(dep, bundled, sizeof(bundled))) {
			void *bh = dlopen_orig(bundled, flags);
			if (bh) {
				DEBUG_PRINT("cross-libc-dlopen: %s -> bundled %s (host copy not used)\n",
				            dep, bundled);
				if (deps.n < CLD_DEPS_MAX)
					deps.h[deps.n++] = bh;
				continue;
			}
			DEBUG_PRINT("cross-libc-dlopen: bundled %s present but would not load\n", bundled);
		}

		char *candidate = NULL;
		if (!musl_guest) {
			void *dep_probe = dlopen_orig(dep, flags);
			if (dep_probe)
				continue;
			DEBUG_PRINT("cross-libc-dlopen: linker refused %s, looking for the file\n", dep);
			candidate = cld_path_from_dlerror();
		}
		if (!candidate)
			candidate = cld_find_candidate(dep, depth);
		if (!candidate) {
			// Nothing opened it and nothing found it. Remember which soname
			// that was: every symbol it would have provided is about to look
			// unresolved, and the report has to say why rather than guess.
			DEBUG_PRINT("cross-libc-dlopen: dependency %s could not be opened at all\n", dep);
			cld_note_unopened(&deps, dep);
			continue; // parent load below surfaces the classic error
		}

		char *dep_canon = canonicalize_file_name(candidate);
		free(candidate);
		if (!dep_canon) {
			cld_note_unopened(&deps, dep);
			continue;
		}
		DEBUG_PRINT("cross-libc-dlopen: loading dependency %s -> %s\n", dep, dep_canon);
		if (is_host_library_path(dep_canon)) {
			void *dh = cld_load(dlopen_orig, dep_canon, flags, depth + 1);
			// Kept so a later failure report can tell "this object's own
			// closure provides it" from "genuinely nobody provides it".
			if (dh && deps.n < CLD_DEPS_MAX)
				deps.h[deps.n++] = dh;
		}
		free(dep_canon);
	}

	// NOW the satisfaction question can be answered: the closure is loaded, so
	// every file a DT_VERNEED record names either exists in this process or
	// genuinely could not be found. Asking before the walk answered "absent"
	// for every one of this object's own dependencies and stripped everything.
	//
	// A musl guest is stripped unconditionally: it has no version info to
	// check, and its libc dependency is about to be dropped.
	needs_strip = musl_guest || (has_tags && !cld_requirements_satisfied(&e));
	if (!needs_strip)
		DEBUG_PRINT("cross-libc-dlopen: %s needs no rewrite, loading it unchanged\n", canon);

	// CROSS_LIBC_DLOPEN_NOSTRIP=1 keeps the version tags but still emits and
	// loads the private copy, which separates "the rewrite broke it" from
	// "being loaded from a different path broke it" in a single A/B. Purely a
	// diagnostic: with the tags intact a genuinely unsatisfiable object just
	// fails to load, and the plain fallback below then reports why.
	const char *nostrip_env = cld_getenv("CROSS_LIBC_DLOPEN_NOSTRIP", NULL);
	int strip_disabled = nostrip_env && strcmp(nostrip_env, "1") == 0;

	void *handle = NULL;
	char *load_path = NULL;
	int dry_run = cld_dryrun_enabled();

	if (needs_strip) {
		DEBUG_PRINT("cross-libc-dlopen: rewriting %s%s\n", canon,
		            strip_disabled ? " (NOSTRIP: version tags kept)" : "");
		if (!strip_disabled)
			cld_strip_versions(&e);
		// drop the edges that would pull musl libc in, every import the
		// guest owns binds to our libc by name instead
		for (size_t i = 0; i < drop_count; i++)
			e.dyn[drop_idx[i]].d_tag = CLD_NEUTRAL_TAG;
		// rename the handful of musl spellings that differ only cosmetically
		// from ours, so a WEAK import does not silently resolve to 0
		cld_apply_renames(&e, dry_run);

		if (dry_run) {
			// Report what WOULD happen and load nothing. Makes the whole
			// rewrite path testable with no GPU and no Alpine.
			fprintf(stderr,
			        " [cross-libc-dlopen.so] >> DRYRUN %s\n"
			        " [cross-libc-dlopen.so] >>   version tags: %s\n"
			        " [cross-libc-dlopen.so] >>   musl NEEDED dropped: %zu\n",
			        canon,
			        !has_tags ? "none present"
			                  : strip_disabled ? "kept (NOSTRIP)" : "stripped",
			        drop_count);
			cld_report_unresolved(&e, canon, &deps, 1);
			cld_free_elf(&e);
			return NULL;
		}

		load_path = cld_emit_copy(e.map, e.size, canon);
		if (load_path) {
			handle = dlopen_orig(load_path, flags);
			if (!handle) {
				// dlerror() is destructive. Read it only when the user asked
				// for a trace; otherwise the plain fallback below produces a
				// fresh message and the CALLER must be able to read it.
				if (cross_libc_dlopen_debug_enabled()) {
					const char *err = dlerror();
					DEBUG_PRINT("cross-libc-dlopen: rewritten load failed: %s\n",
					            err ? err : "unknown");
					// The rewrite is ours, so a failure here is ours to
					// explain. Name every symbol, not just ld.so's first.
					cld_report_unresolved(&e, canon, &deps, 1);
				}
			}
		}
	} else if (dry_run) {
		fprintf(stderr,
		        " [cross-libc-dlopen.so] >> DRYRUN %s: no rewrite needed "
		        "(every required version is satisfied)\n", canon);
		cld_report_unresolved(&e, canon, &deps, 1);
		cld_free_elf(&e);
		return NULL;
	}

	if (!handle) {
		// plain load fallback, surfaces the classic error message
		// users know how to read
		//
		// Upstream read dlerror() here unconditionally and only DEBUG_PRINTed
		// it, which CONSUMED the message: with debug off the caller's own
		// dlerror() returned NULL and the "classic error message" never
		// reached anyone. Measured: the T2 harness printed
		// "FAILED: dlopen: (null)". Leave it in place unless tracing.
		handle = dlopen_orig(canon, flags);
		if (!handle && cross_libc_dlopen_debug_enabled()) {
			const char *err = dlerror();
			DEBUG_PRINT("cross-libc-dlopen: plain fallback failed: %s\n", err ? err : "unknown");
			cld_report_unresolved(&e, canon, &deps, 1);
			// The report probes with dlsym, and every probe that misses
			// REPLACES the pending dlerror() message. The caller, who is about
			// to ask for it, would get "cross-libc-dlopen.so: undefined symbol:
			// ...", this object blamed for a failure in a different one,
			// instead of ld.so's real explanation. Re-running the load puts
			// the right message back. One extra failed dlopen, only in a trace
			// run. Same class of bug as the destructive dlerror() upstream
			// had, reached from the other side.
			void *retry = dlopen_orig(canon, flags);
			if (retry)
				handle = retry;   // cannot happen; never leak a handle if it does
		}
	}

	cld_free_elf(&e);
	if (handle)
		cld_cache_put(canon, handle);
	return handle;
}

// Attempt a cross-libc load of a host library, *handled tells the caller
// whether an attempt was made
static void *cld_attempt(dlopen_func_t dlopen_orig, const char *filename, int flags, int *handled) {
	*handled = 0;

	int mode = cross_libc_dlopen_mode();
	if (!mode || !filename || !*filename) {
		DEBUG_PRINT("attempt bail: mode=%d filename=%s\n", mode, filename ? filename : "(null)");
		return NULL;
	}
	if (flags & RTLD_NOLOAD) {
		DEBUG_PRINT("attempt bail: NOLOAD %s\n", filename);
		return NULL;
	}

	if (*filename != '/')
		return NULL;

	if (!is_host_library_path(filename))
		return NULL;

	char *canon = canonicalize_file_name(filename);
	if (!canon)
		return NULL;
	if (!is_host_library_path(canon)) {
		// symlinks pointing back into the AppImage stay untouched
		free(canon);
		return NULL;
	}

	*handled = 1;
	cld_scan_providers();

	// host drivers are load once, NODELETE makes sure a stray dlclose
	// from one caller cannot yank mappings other callers still hold,
	// the cache hands the same handle out to everyone
	flags |= RTLD_NODELETE;

	void *result = cld_load(dlopen_orig, canon, flags, 0);
	free(canon);
	return result;
}

// Intercept dlopen for host libraries
VISIBLE void *dlopen(const char *filename, int flags) {
	dlopen_func_t dlopen_orig = dlsym(RTLD_NEXT, "dlopen");
	if (!dlopen_orig) {
		DEBUG_PRINT("Error getting original dlopen symbol: %s\n", dlerror());
		return NULL;
	}

	// NULL filename means the caller wants a handle to the main program
	if (!filename || !*filename)
		return dlopen_orig(filename, flags);

	int handled = 0;
	void *host = cld_attempt(dlopen_orig, filename, flags, &handled);
	if (handled) {
		if (host) {
			// a successful load may have brought libva in; the call is
			// one branch once it has fired (see the LIBVA section above)
			cld_va_setup();
			DEBUG_PRINT("cross-libc dlopen success: %s\n", filename);
		} else {
			DEBUG_PRINT("cross-libc dlopen failed: %s\n", filename);
		}
		return host;
	}

	DEBUG_PRINT("dlopen pass-through: %s\n", filename);
	void *pass = dlopen_orig(filename, flags);
	if (pass)
		cld_va_setup();
	return pass;
}
