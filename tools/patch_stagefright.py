#!/usr/bin/env python3
"""patch_stagefright.py <libstagefright.so> <out.so>

Make MediaCodecList::getInstance() use getLocalInstance().

getInstance() asks media.player for the codec list. In the container that is
Samsung's mediaserver, whose IMediaCodecList differs from the GSI's, so
findMatchingCodecs() reads garbage and SoundPool's decoder threads spin on it in
system_server and SystemUI (hot phone, logd flooded). getLocalInstance() builds
the list in-process from the vendor's HALs instead.

Both exported symbols are one-instruction thunks. getInstance() is a wrapper that
tail-branches to the implementation, and findMatchingCodecs() calls that
implementation directly, so both entries get a branch to the real
getLocalInstance(). All return sp<IMediaCodecList> through x8, so the tail branch
is ABI-safe. For non-mediaserver uids getLocalInstance() builds the list with
MediaCodecList::Build(). Fails loudly if the layout differs.
"""
import struct, sys

GET = b"_ZN7android14MediaCodecList11getInstanceEv\0"
LOCAL = b"_ZN7android14MediaCodecList16getLocalInstanceEv\0"
data = bytearray(open(sys.argv[1], "rb").read())
if data[:5] != b"\x7fELF\x02":
    sys.exit("not a 64-bit ELF")
phoff, = struct.unpack_from("<Q", data, 0x20)
phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
ph = [struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize) for i in range(phnum)]
loads = [p for p in ph if p[0] == 1]
def off(va):
    for p in loads:
        if p[3] <= va < p[3] + p[5]:
            return va - p[3] + p[2]
    sys.exit(f"vaddr {va:#x} not mapped")
dyn = next(p for p in ph if p[0] == 2)
tags = {}
for i in range(0, dyn[5], 16):
    tag, val = struct.unpack_from("<QQ", data, dyn[2] + i)
    tags[tag] = val
    if tag == 0:
        break
symtab, strtab = off(tags[6]), off(tags[5])
def sym(name):
    # DT_SYMTAB runs up to DT_STRTAB in these binaries
    for s in range(symtab, strtab, 24):
        st_name, _, _, _, st_value, _ = struct.unpack_from("<IBBHQQ", data, s)
        if data[strtab + st_name:strtab + st_name + len(name)] == name:
            return st_value
    sys.exit(f"symbol not found: {name[:-1].decode()}")
def b_target(va):
    i, = struct.unpack_from("<I", data, off(va))
    if i >> 26 != 0b000101:
        sys.exit(f"expected a b thunk at {va:#x}, found {i:#010x}")
    imm = i & 0x3ffffff
    if imm & (1 << 25):
        imm -= 1 << 26
    return va + imm * 4
entry = b_target(sym(GET))
local = b_target(sym(LOCAL))
# The wrapper's only unconditional forward branch reaches the implementation.
impl = None
for va in range(entry, entry + 0x60, 4):
    i, = struct.unpack_from("<I", data, off(va))
    if i >> 26 == 0b000101 and (i & 0x3ffffff) < (1 << 25):
        impl = b_target(va)
        break
if impl is None or impl <= va:
    sys.exit("implementation branch not found in getInstance wrapper")
for va in (entry, impl):
    struct.pack_into("<I", data, off(va), (0b000101 << 26) | (((local - va) >> 2) & 0x3ffffff))
open(sys.argv[2], "wb").write(data)
print(f"getInstance {entry:#x} and impl {impl:#x} -> getLocalInstance {local:#x}")
