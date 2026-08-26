/* T6.2 -- which DEFINITION did each object in the process actually bind?
 *
 * `LD_DEBUG=bindings` prints the version a reference ASKED for. It does not
 * print the definition the reference GOT, and for the version-binding trap
 * those are exactly the two things that differ: an unversioned reference asks
 * for nothing and receives glibc's obsolete definition (E22).
 *
 * So read the answer out of the process instead of arguing about it. For every
 * loaded object, walk its relocations, find the GOT slot for the named symbol,
 * and report the address the loader put there -- then say which file that
 * address is in and, when it is libc, which VERSION of the symbol it is.
 *
 * The verdict that matters is not per object, it is per symbol across all of
 * them: if two objects in one driver stack bound different implementations of
 * one entry point, and that entry point takes a struct whose layout changed
 * between those implementations, then any such struct crossing between them is
 * read two different ways. That is the shape of the pthread_cond_t ABI change
 * of 2003, and section 4.1 is the story of it costing an afternoon.
 *
 *      tests/bindprobe <library> [--init <fn>] <symbol>...
 *
 * --init names a function called as `int fn(unsigned)` with 0 before the scan,
 * for drivers that pull the rest of their chain in lazily on first use
 * (libcuda.so.1 dlopens libdxcore.so and the real driver from inside cuInit).
 *
 * Run it under LD_BIND_NOW=1. Without it a lazily-bound slot still holds the
 * PLT resolver stub and the reading is of nothing. Eager binding changes WHEN
 * the choice is made, never WHICH definition is chosen.
 *
 * Exit 0 if every symbol is bound uniformly, 1 if any is mixed, 2 on a usage
 * or load error -- so "mixed" is distinguishable from "could not measure".
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Two relocation types carry the address the loader chose for a named symbol:
 * the PLT slot and the GOT entry. What they MEAN is architecture independent.
 * What they are NUMBERED is not, so they are a table here rather than two
 * constants inlined into the scan.
 *
 * ⚠ An unknown architecture must not fall through to an empty table. With no
 * type matching, the scan records nothing, every symbol prints "(no loaded
 * object references it)", and that reads as a finding about the driver stack
 * rather than as a probe that cannot run here. main() does catch the total
 * case and exits 2 with "nothing was measured", but a reader skimming the
 * per-symbol lines meets the wrong sentence first. Refuse at build time and
 * name what to add.
 */
#if defined(__x86_64__)
#  define CLD_R_JUMP_SLOT R_X86_64_JUMP_SLOT
#  define CLD_R_GLOB_DAT  R_X86_64_GLOB_DAT
#elif defined(__aarch64__)
#  define CLD_R_JUMP_SLOT R_AARCH64_JUMP_SLOT
#  define CLD_R_GLOB_DAT  R_AARCH64_GLOB_DAT
#else
#  error "bindprobe knows only x86-64 and aarch64 relocation types; add yours above"
#endif

#define MAX_SYMS 16
#define MAX_OBJS 256

/* The version names the trap set actually uses. Trying a fixed list is enough:
 * version_traps.py has already established which names are involved, and a
 * name that does not resolve simply does not print. */
static const char *VERSIONS[] = {
	"GLIBC_2.2.5", "GLIBC_2.3", "GLIBC_2.3.2", "GLIBC_2.3.3", "GLIBC_2.3.4",
	"GLIBC_2.4", "GLIBC_2.14", "GLIBC_2.17", "GLIBC_2.32", "GLIBC_2.34", NULL
};

struct binding {
	const char *obj;
	void *addr;
};

struct sym {
	const char *name;
	struct binding b[MAX_OBJS];
	int n;
};

static struct sym syms[MAX_SYMS];
static int nsyms;

/* A d_ptr in a mapped PT_DYNAMIC is absolute on some ports and link-time on
 * others, and dereferencing the wrong guess is a segfault. dladdr answers
 * safely: it searches the loaded objects for an address and never dereferences
 * it, so the candidate that lands inside THIS object is the right one. */
static const void *dyn_ptr(ElfW(Addr) raw, ElfW(Addr) base) {
	Dl_info di;
	if (raw && dladdr((void *)raw, &di) && di.dli_fbase == (void *)base)
		return (const void *)raw;
	if (dladdr((void *)(raw + base), &di) && di.dli_fbase == (void *)base)
		return (const void *)(raw + base);
	return NULL;
}

static ElfW(Xword) dyn_val(const ElfW(Dyn) *d, ElfW(Sxword) tag) {
	for (; d->d_tag != DT_NULL; d++)
		if (d->d_tag == tag) return d->d_un.d_val;
	return 0;
}

static void record(const char *obj, const char *name, void *addr) {
	for (int i = 0; i < nsyms; i++) {
		if (strcmp(syms[i].name, name) != 0) continue;
		/* One object can carry both a JUMP_SLOT and a GLOB_DAT for the same
		 * name. Listing it twice would read as a disagreement where there is
		 * none, so the first entry wins. */
		for (int j = 0; j < syms[i].n; j++)
			if (strcmp(syms[i].b[j].obj, obj) == 0) return;
		if (syms[i].n >= MAX_OBJS) return;
		syms[i].b[syms[i].n].obj = obj;
		syms[i].b[syms[i].n].addr = addr;
		syms[i].n++;
		return;
	}
}

/* One object: find every relocation naming a symbol we care about and read the
 * slot the loader filled in.
 *
 * The symbol index is used without a bound because there is nothing to bound it
 * against: DT_SYMTAB carries no count, and the only honest sources are the hash
 * tables. It is safe here for a reason rather than by luck -- every object this
 * walks has already been relocated by ld.so, which resolved these same indices
 * first and would have died on a bad one. Do not reuse this on an object read
 * off disk; that is what the fuzzed rewriter in cross-libc-dlopen.c is for. */
static void scan_relocs(const char *obj, ElfW(Addr) base,
                        const ElfW(Rela) *rela, ElfW(Xword) bytes,
                        const ElfW(Sym) *symtab, const char *strtab) {
	if (!rela || !symtab || !strtab || !bytes) return;
	for (ElfW(Xword) i = 0; i < bytes / sizeof *rela; i++) {
		unsigned type = ELF64_R_TYPE(rela[i].r_info);
		if (type != CLD_R_JUMP_SLOT && type != CLD_R_GLOB_DAT) continue;
		unsigned long si = ELF64_R_SYM(rela[i].r_info);
		if (!si) continue;
		const char *name = strtab + symtab[si].st_name;
		for (int s = 0; s < nsyms; s++) {
			if (strcmp(name, syms[s].name) != 0) continue;
			void **slot = (void **)(base + rela[i].r_offset);
			record(obj, name, *slot);
			break;
		}
	}
}

static int visit(struct dl_phdr_info *info, size_t size, void *data) {
	(void)size; (void)data;
	const char *name = (info->dlpi_name && *info->dlpi_name)
	                   ? info->dlpi_name : "(main program)";
	for (int i = 0; i < info->dlpi_phnum; i++) {
		if (info->dlpi_phdr[i].p_type != PT_DYNAMIC) continue;
		const ElfW(Dyn) *d =
			(const ElfW(Dyn) *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
		ElfW(Addr) base = info->dlpi_addr;
		const ElfW(Sym) *symtab = dyn_ptr(dyn_val(d, DT_SYMTAB), base);
		const char *strtab = dyn_ptr(dyn_val(d, DT_STRTAB), base);
		const ElfW(Rela) *jmprel = dyn_ptr(dyn_val(d, DT_JMPREL), base);
		const ElfW(Rela) *dynrel = dyn_ptr(dyn_val(d, DT_RELA), base);
		if (dyn_val(d, DT_PLTREL) != DT_RELA) jmprel = NULL;   /* REL, not RELA */
		scan_relocs(name, base, jmprel, dyn_val(d, DT_PLTRELSZ), symtab, strtab);
		scan_relocs(name, base, dynrel, dyn_val(d, DT_RELASZ), symtab, strtab);
	}
	return 0;
}

/* Name an address: the file it lives in, plus the symbol version when the file
 * is a libc that defines the name at more than one version. */
static void describe(void *libc, const char *sym, void *addr, char *out, size_t n) {
	Dl_info di;
	/* dladdr leaves di untouched when it fails, so the offset branch below
	 * must never be reached on that path -- reading dli_fbase then is reading
	 * an uninitialised pointer. */
	int known = dladdr(addr, &di) && di.dli_fname;
	const char *file = known ? di.dli_fname : "?";
	const char *slash = strrchr(file, '/');
	const char *shortf = slash ? slash + 1 : file;

	const char *ver = NULL;
	if (libc) {
		for (int i = 0; VERSIONS[i]; i++) {
			void *v = dlvsym(libc, sym, VERSIONS[i]);
			if (v == addr) { ver = VERSIONS[i]; break; }
		}
	}
	if (ver)         snprintf(out, n, "%s @%s", shortf, ver);
	else if (known)  snprintf(out, n, "%s+0x%lx", shortf,
	                          (unsigned long)((char *)addr - (char *)di.dli_fbase));
	else             snprintf(out, n, "0x%lx (in no loaded object)",
	                          (unsigned long)(uintptr_t)addr);
}

int main(int argc, char **argv) {
	setvbuf(stdout, NULL, _IONBF, 0);

	if (argc < 3) {
		printf("usage: bindprobe <library> [--init <fn>] <symbol>...\n");
		return 2;
	}
	const char *lib = argv[1];
	const char *initfn = NULL;
	int a = 2;
	if (strcmp(argv[a], "--init") == 0) {
		if (argc < a + 3) { printf("usage: --init needs a function name\n"); return 2; }
		initfn = argv[a + 1];
		a += 2;
	}
	for (; a < argc; a++) {
		if (nsyms == MAX_SYMS) {
			/* Never drop one quietly: a symbol that was asked for and not
			 * measured would be missing from the report with no explanation. */
			printf("FAILED: more than %d symbols; raise MAX_SYMS\n", MAX_SYMS);
			return 2;
		}
		syms[nsyms++].name = argv[a];
	}
	if (!nsyms) { printf("usage: name at least one symbol\n"); return 2; }

	void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
	if (!h) { printf("FAILED: dlopen: %s\n", dlerror()); return 2; }

	if (initfn) {
		int (*fn)(unsigned) = (int (*)(unsigned))dlsym(h, initfn);
		if (!fn) { printf("FAILED: no %s in %s\n", initfn, lib); return 2; }
		int r = fn(0);
		printf("  %s(0) -> %d%s\n", initfn, r,
		       r == 0 ? "" : "  (the lazy chain may not have loaded)");
	}

	/* RTLD_NOLOAD: name the libc already in the process, never map a second
	 * one. Section 7. */
	void *libc = dlopen("libc.so.6", RTLD_NOLOAD | RTLD_LAZY);

	dl_iterate_phdr(visit, NULL);

	int mixed = 0, measured = 0;
	for (int s = 0; s < nsyms; s++) {
		printf("\n  %s\n", syms[s].name);
		if (!syms[s].n) { printf("      (no loaded object references it)\n"); continue; }
		measured++;
		for (int i = 0; i < syms[s].n; i++) {
			char what[256];
			describe(libc, syms[s].name, syms[s].b[i].addr, what, sizeof what);
			const char *slash = strrchr(syms[s].b[i].obj, '/');
			printf("      %-46s -> %s\n",
			       slash ? slash + 1 : syms[s].b[i].obj, what);
		}
		int distinct = 0;
		for (int i = 0; i < syms[s].n; i++) {
			int seen = 0;
			for (int j = 0; j < i; j++)
				if (syms[s].b[j].addr == syms[s].b[i].addr) { seen = 1; break; }
			if (!seen) distinct++;
		}
		if (distinct > 1) { printf("      VERDICT: MIXED (%d implementations)\n", distinct); mixed++; }
		else printf("      VERDICT: uniform\n");
	}

	printf("\n%s: %d symbol(s) measured, %d MIXED\n",
	       mixed ? "BINDINGS MIXED" : "BINDINGS UNIFORM", measured, mixed);
	if (!measured) {
		printf("nothing was measured, so this proves nothing\n");
		return 2;
	}
	return mixed != 0;
}
