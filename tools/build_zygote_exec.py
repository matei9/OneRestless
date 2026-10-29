#!/usr/bin/env python3
"""build_zygote_exec.py <template zygote_exec> <classpath.env> <out>
   build_zygote_exec.py --inherit-env <template zygote_exec> <out>

assets/zygote_exec is a tiny hand-written aarch64 static binary: it creates the
zygote/usap sockets (fds 3/4), points stdio at /dev/null and execve()s
app_process64 with a *fixed* environment table. The classpaths in that table
are Android-version specific (the 23.2 build's list made the Android 17 zygote
die with NoClassDefFoundError in SystemServiceRegistry).

This rewrites the environment block: every VAR=value from classpath.env replaces
the matching entry (new VARs are appended), then the envp pointer table is
re-emitted at the end of the file, the single `adr x2, envp` before the execve
is re-encoded and the PT_LOAD sizes are updated. Code and argv are untouched."""
import struct, sys
BASE = 0x400000
ARGV_END = 0x4B8            # end of argv pointer table == start of env strings
ADR_ENVP = 0x78 + 0x1F0     # file offset of `adr x2, <envp>`

INHERIT = sys.argv[1] == "--inherit-env"
if INHERIT:
    tpl, out = sys.argv[2:4]; envfile = None
else:
    tpl, envfile, out = sys.argv[1:4]
d = bytearray(open(tpl, "rb").read())
assert d[:4] == b"\x7fELF" and struct.unpack_from("<H", d, 0x12)[0] == 0xB7, "not aarch64 ELF"

def decode_adr(ins, pc):
    assert ins & 0x9F000000 == 0x10000000, hex(ins)
    imm = ((ins >> 5) & 0x7FFFF) << 2 | (ins >> 29) & 3
    if imm & (1 << 20): imm -= 1 << 21
    return pc + imm, ins & 0x1F

def encode_adr(rd, pc, target):
    imm = target - pc
    assert -(1 << 20) <= imm < (1 << 20)
    imm &= (1 << 21) - 1
    return 0x10000000 | (imm & 3) << 29 | (imm >> 2) << 5 | rd

ins = struct.unpack_from("<I", d, ADR_ENVP)[0]
envp_va, rd = decode_adr(ins, BASE + ADR_ENVP)
assert rd == 2, "expected adr x2"
env, off = [], envp_va - BASE
while (p := struct.unpack_from("<Q", d, off)[0]):
    env.append(bytes(d[p - BASE:d.index(0, p - BASE)]).decode()); off += 8

if INHERIT:
    # --inherit-env: execve() gets the caller's own environment instead of the
    # baked table, so master_inner.sh can compute classpaths at runtime
    # (derive_classpath) for whatever GSI/APEX mix is mounted. `adr x2, envp`
    # becomes `b stub`; the stub derives envp from the untouched entry stack
    # (sp -> argc, argv[argc], NULL, envp...) and branches back. The code never
    # moves sp, so the entry stack is still in place at the execve.
    body = bytearray(d)
    body += b"\0" * (-len(body) % 4)
    stub = BASE + len(body)
    pc_back = BASE + ADR_ENVP + 4
    def b(pc, tgt): return 0x14000000 | (((tgt - pc) >> 2) & 0x3FFFFFF)
    insns = [
        0xF94003E2,                                            # ldr x2, [sp]          ; argc
        0x8B200000 | 2 << 16 | 3 << 13 | 3 << 10 | 31 << 5 | 2,  # add x2, sp, x2, uxtx #3
        0x91000000 | 16 << 10 | 2 << 5 | 2,                    # add x2, x2, #16       ; skip argc + argv NULL
    ]
    for i in insns: body += struct.pack("<I", i)
    body += struct.pack("<I", b(stub + 4 * len(insns), pc_back))   # b back
    struct.pack_into("<I", body, ADR_ENVP, b(BASE + ADR_ENVP, stub))
    phoff = struct.unpack_from("<Q", body, 0x20)[0]
    struct.pack_into("<QQ", body, phoff + 32, len(body), len(body))
    open(out, "wb").write(body)
    print(f"{out}: {len(body)} bytes, inherits caller environment (stub @ {stub:#x})")
    sys.exit(0)

new = {}
for line in open(envfile):
    line = line.strip()
    if line and not line.startswith("#"):
        k, v = line.split("=", 1); new[k] = v
keys = [e.split("=", 1)[0] for e in env]
env = [f"{k}={new[k]}" if k in new else e for k, e in zip(keys, env)]
env += [f"{k}={v}" for k, v in new.items() if k not in keys]

body = bytearray(d[:ARGV_END]); ptrs = []
for e in env:
    ptrs.append(BASE + len(body)); body += e.encode() + b"\0"
body += b"\0" * (-len(body) % 8)
envp_new = BASE + len(body)
for p in ptrs + [0]: body += struct.pack("<Q", p)
struct.pack_into("<I", body, ADR_ENVP, encode_adr(2, BASE + ADR_ENVP, envp_new))
phoff = struct.unpack_from("<Q", body, 0x20)[0]
struct.pack_into("<QQ", body, phoff + 32, len(body), len(body))   # p_filesz, p_memsz
open(out, "wb").write(body)
print(f"{out}: {len(body)} bytes, {len(env)} env vars, envp @ {envp_new:#x}")
for e in env: print("  " + (e if len(e) < 90 else e[:60] + f"... ({e.count(':') + 1} entries)"))
