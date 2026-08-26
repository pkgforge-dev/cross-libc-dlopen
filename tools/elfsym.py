"""Minimal pure-Python ELF64 dynamic-symbol reader (no external deps)."""
import struct, sys

STT = {0:'NOTYPE',1:'OBJECT',2:'FUNC',3:'SECTION',4:'FILE',6:'TLS',10:'GNU_IFUNC'}
STB = {0:'LOCAL',1:'GLOBAL',2:'WEAK'}

class Elf:
    def __init__(self, path):
        self.path = path
        self.d = open(path,'rb').read()
        d = self.d
        assert d[:4] == b'\x7fELF' and d[4] == 2, f'{path}: not ELF64'
        (self.e_type, self.e_machine, _, self.e_entry, self.e_phoff, self.e_shoff,
         _, _, self.e_phentsize, self.e_phnum, self.e_shentsize, self.e_shnum,
         self.e_shstrndx) = struct.unpack_from('<HHIQQQIHHHHHH', d, 16)
        self.phdrs = []
        for i in range(self.e_phnum):
            o = self.e_phoff + i*self.e_phentsize
            p_type,p_flags,p_offset,p_vaddr,_,p_filesz,p_memsz,_ = struct.unpack_from('<IIQQQQQQ', d, o)
            self.phdrs.append((p_type,p_offset,p_vaddr,p_filesz,p_memsz))
        self.shdrs = []
        for i in range(self.e_shnum):
            o = self.e_shoff + i*self.e_shentsize
            (sh_name,sh_type,sh_flags,sh_addr,sh_offset,sh_size,sh_link,sh_info,
             sh_align,sh_entsize) = struct.unpack_from('<IIQQQQIIQQ', d, o)
            self.shdrs.append(dict(name=sh_name,type=sh_type,addr=sh_addr,off=sh_offset,
                                   size=sh_size,link=sh_link,entsize=sh_entsize))
        self.dyn = self._read_dynamic()

    def v2o(self, vaddr):
        for p_type,off,vaddr0,filesz,memsz in self.phdrs:
            if p_type == 1 and vaddr0 <= vaddr < vaddr0+filesz:
                return off + (vaddr - vaddr0)
        return None

    def _read_dynamic(self):
        out = []
        for p_type,off,vaddr,filesz,memsz in self.phdrs:
            if p_type != 2: continue          # PT_DYNAMIC
            for i in range(filesz//16):
                tag,val = struct.unpack_from('<qQ', self.d, off + i*16)
                if tag == 0: break
                out.append((tag,val))
        return out

    def dtag(self, t):
        return [v for tg,v in self.dyn if tg == t]

    def _cstr(self, base, off):
        end = self.d.index(b'\x00', base+off)
        return self.d[base+off:end].decode('utf-8','replace')

    def needed(self):
        strtab = self.v2o(self.dtag(5)[0]) if self.dtag(5) else None
        if strtab is None: return []
        return [self._cstr(strtab,v) for v in self.dtag(1)]

    def soname(self):
        strtab = self.v2o(self.dtag(5)[0]) if self.dtag(5) else None
        s = self.dtag(14)
        return self._cstr(strtab,s[0]) if (strtab is not None and s) else None

    def _dynsym_span(self):
        """(offset, count, stroff) for .dynsym -- prefer section headers, else GNU_HASH."""
        for sh in self.shdrs:
            if sh['type'] == 11 and sh['entsize'] == 24:      # SHT_DYNSYM
                stro = self.shdrs[sh['link']]['off']
                return sh['off'], sh['size']//24, stro
        symo = self.v2o(self.dtag(6)[0]); stro = self.v2o(self.dtag(5)[0])
        gh = self.dtag(0x6ffffef5)
        if gh:
            o = self.v2o(gh[0])
            nbucket,symoffset,bloom_size,_ = struct.unpack_from('<IIII', self.d, o)
            bo = o+16+bloom_size*8
            buckets = struct.unpack_from(f'<{nbucket}I', self.d, bo)
            last = max(buckets) if buckets else symoffset
            co = bo+nbucket*4
            if last >= symoffset:
                i = last - symoffset
                while True:
                    h, = struct.unpack_from('<I', self.d, co+i*4)
                    last = symoffset+i
                    if h & 1: break
                    i += 1
            return symo, last+1, stro
        raise RuntimeError('no dynsym')

    def symbols(self):
        symo,n,stro = self._dynsym_span()
        out = []
        for i in range(n):
            st_name,st_info,st_other,st_shndx,st_value,st_size = struct.unpack_from('<IBBHQQ', self.d, symo+i*24)
            if st_name == 0: continue
            out.append(dict(idx=i, name=self._cstr(stro,st_name), bind=STB.get(st_info>>4,'?'),
                            type=STT.get(st_info&0xf,'?'), shndx=st_shndx,
                            vis=st_other & 3, value=st_value))
        return out

    def versym(self):
        """DT_VERSYM as a list indexed by dynsym index, or None when absent.

        Entry & 0x7fff is the version index; & 0x8000 marks a NON-DEFAULT
        (hidden) definition.  Index 0 is local, 1 is global/unversioned."""
        vs = self.dtag(0x6ffffff0)
        if not vs: return None
        o = self.v2o(vs[0])
        if o is None: return None
        _, n, _ = self._dynsym_span()
        # The count comes from the hash tables, the table from DT_VERSYM: a
        # stripped or truncated object can disagree. Read what is actually
        # there rather than raising out of the middle of an inventory run.
        n = min(n, max(0, (len(self.d) - o) // 2))
        return list(struct.unpack_from(f'<{n}H', self.d, o))

    def verdef_index(self):
        """{version index: name} from DT_VERDEF, base entry included."""
        vd = self.dtag(0x6ffffffc); num = self.dtag(0x6ffffffd)
        if not vd: return {}
        base = self.v2o(vd[0]); stro = self.v2o(self.dtag(5)[0]); res = {}
        pos = 0
        for _ in range(num[0] if num else 512):
            ver,flags,ndx,cnt,hsh,aux,nxt = struct.unpack_from('<HHHHIII', self.d, base+pos)
            nm, = struct.unpack_from('<I', self.d, base+pos+aux)
            res[ndx] = self._cstr(stro,nm)
            if not nxt: break
            pos += nxt
        return res

    def exports(self):
        return {s['name'] for s in self.symbols()
                if s['shndx'] != 0 and s['bind'] in ('GLOBAL','WEAK') and s['vis'] == 0}

    def imports(self):
        return {s['name'] for s in self.symbols()
                if s['shndx'] == 0 and s['bind'] in ('GLOBAL','WEAK')}

    def weak_imports(self):
        return {s['name'] for s in self.symbols() if s['shndx'] == 0 and s['bind'] == 'WEAK'}

    def verneed(self):
        """{soname: {versions}} required."""
        vn = self.dtag(0x6ffffffe); num = self.dtag(0x6fffffff)
        if not vn: return {}
        base = self.v2o(vn[0]); stro = self.v2o(self.dtag(5)[0]); res = {}
        pos = 0
        for _ in range(num[0] if num else 64):
            ver,cnt,file_,aux,nxt = struct.unpack_from('<HHIII', self.d, base+pos)
            fn = self._cstr(stro, file_); res.setdefault(fn,set())
            apos = pos+aux
            for _ in range(cnt):
                h,flags,other,nm,anx = struct.unpack_from('<IHHII', self.d, base+apos)
                res[fn].add(self._cstr(stro,nm))
                if not anx: break
                apos += anx
            if not nxt: break
            pos += nxt
        return res

    def verdef(self):
        vd = self.dtag(0x6ffffffc); num = self.dtag(0x6ffffffd)
        if not vd: return set()
        base = self.v2o(vd[0]); stro = self.v2o(self.dtag(5)[0]); res=set()
        pos = 0
        for _ in range(num[0] if num else 512):
            ver,flags,ndx,cnt,hsh,aux,nxt = struct.unpack_from('<HHHHIII', self.d, base+pos)
            if not (flags & 1):
                nm, = struct.unpack_from('<I', self.d, base+pos+aux)
                res.add(self._cstr(stro,nm))
            if not nxt: break
            pos += nxt
        return res

if __name__ == '__main__':
    for p in sys.argv[1:]:
        e = Elf(p)
        print(f'== {p}  soname={e.soname()}')
        print('   NEEDED:', e.needed())
        print(f'   exports={len(e.exports())} imports={len(e.imports())}')
        vn = e.verneed()
        if vn: print('   VERNEED:', {k: sorted(v)[:6] for k,v in vn.items()})
