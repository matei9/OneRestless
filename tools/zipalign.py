#!/usr/bin/env python3
"""zipalign.py <in.apk> <out.apk> - minimal zipalign (4-byte, .so on 16 KiB).
Fallback for build hosts whose SDK ships only a Windows zipalign.exe."""
import sys, zipfile, struct
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as zi, open(dst, "wb") as f:
    zo = zipfile.ZipFile(f, "w")
    for info in zi.infolist():
        data = zi.read(info.filename)
        ni = zipfile.ZipInfo(info.filename, info.date_time)
        ni.compress_type = info.compress_type
        ni.external_attr = info.external_attr
        if ni.compress_type == zipfile.ZIP_STORED:
            align = 16384 if info.filename.endswith(".so") else 4
            name_len = len(info.filename.encode("utf-8"))
            hdr_end = f.tell() + 30 + name_len + 4   # +4: extra field header
            pad = (-hdr_end) % align
            ni.extra = struct.pack("<HH", 0xD935, pad) + b"\0" * pad
        zo.writestr(ni, data)
    zo.close()
