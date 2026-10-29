#!/usr/bin/env python3
"""patch_svcconn.py <svcconn_apktool_dir>

Stub BpfNetMaps methods that NPE when the TrebleDroid nobpf overlay has
disabled BPF-map initialization: the overlay turns off the main netd BPF
setup for the connectivity service, but ConnectivityService continues to call
these per-UID / per-net policy methods and they deref their now-null static
map fields (sL4sEnabledMap, sLocalNet*Map, ...).

Patched methods:
  - setL4sEnabled(Z)V                                   (ECN/L4S toggle)
  - incrementLnpGenerationId(Z)V                        (private; called below)
  - removeLocalNetHostAllowlistForInterface(I)V
  - addLocalNetAccess(ILjava/lang/String;Ljava/net/InetAddress;IIZ)V
  - addLocalNetUidAccess(ILjava/lang/String;)V
  - addLocalNetUidHostAccess(IILjava/net/InetAddress;)V
  - removeLocalNetAccess(ILjava/lang/String;Ljava/net/InetAddress;II)V
  - removeLocalNetUidAccess(ILjava/lang/String;)V
  - updateLocalNetAccessMap(.../LocalNetAccessKey;Z)V   (private; called by the above)
  - updateLocalNetUidHostAllowlistMap(.../LocalNetUidHostAllowlistKey;Z)V

All are void-returning policy writes. With the maps null they'd throw;
stubbing them matches the overlay's intent (connectivity continues without
per-UID BPF enforcement, like TrebleDroid's PHH fallback).
"""
import re, sys
from pathlib import Path

ROOT = Path(sys.argv[1])
BNM = ROOT / "smali/android/net/connectivity/com/android/server/BpfNetMaps.smali"
if not BNM.exists():
    print(f"BpfNetMaps.smali not found at {BNM}", file=sys.stderr)
    sys.exit(1)

STUBS = [
    # (method sig as it appears after `.method <mods>`, modifiers)
    ("setL4sEnabled(Z)V",                                   "public"),
    ("incrementLnpGenerationId(Z)V",                        "private"),
    ("removeLocalNetHostAllowlistForInterface(I)V",         "public"),
    ("addLocalNetAccess(ILjava/lang/String;Ljava/net/InetAddress;IIZ)V", "public"),
    ("addLocalNetUidAccess(ILjava/lang/String;)V",          "public"),
    ("addLocalNetUidHostAccess(IILjava/net/InetAddress;)V", "public"),
    ("removeLocalNetAccess(ILjava/lang/String;Ljava/net/InetAddress;II)V", "public"),
    ("removeLocalNetUidAccess(ILjava/lang/String;)V",       "public"),
    ("updateLocalNetAccessMap(Landroid/net/connectivity/com/android/net/module/util/bpf/LocalNetAccessKey;Z)V", "private"),
    ("updateLocalNetUidHostAllowlistMap(Landroid/net/connectivity/com/android/net/module/util/bpf/LocalNetUidHostAllowlistKey;Z)V", "private"),
]

text = BNM.read_text()
patched, missing = 0, []
for sig, mods in STUBS:
    # Match `.method <mods>[ <extra>] <sig>` ... `.end method` greedily to .end method
    # Allow for extra modifiers (static, final, synthetic) between <mods> and sig.
    pat = re.compile(
        r"^(\.method " + re.escape(mods) + r"[^\n]*\b" + re.escape(sig) + r"\n)(.*?)(^\.end method$)",
        re.DOTALL | re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        missing.append(sig)
        continue
    header = m.group(1)
    new_body = "    .locals 0\n\n    return-void\n"
    text = text[:m.start()] + header + new_body + m.group(3) + text[m.end():]
    patched += 1
    print(f"  ok  BpfNetMaps->{sig}  [stub]")

BNM.write_text(text)
print(f"\n{patched}/{len(STUBS)} methods patched")
if missing:
    print("MISSING:")
    for s in missing:
        print(f"  {s}")
    sys.exit(1)
