#!/usr/bin/env python3
"""graft_dex.py <stock.jar> <rebuilt.jar> <out.jar> classesN.dex [...]
Copy stock.jar, replacing only the named dex entries with those from
rebuilt.jar. Everything else stays byte-identical (and dex stays STORED)."""
import sys, zipfile
stock, built, out, names = sys.argv[1], sys.argv[2], sys.argv[3], set(sys.argv[4:])
with zipfile.ZipFile(stock) as zs, zipfile.ZipFile(built) as zb, \
     zipfile.ZipFile(out, "w") as zo:
    for info in zs.infolist():
        data = zb.read(info.filename) if info.filename in names else zs.read(info.filename)
        ni = zipfile.ZipInfo(info.filename, info.date_time)
        ni.compress_type = info.compress_type; ni.external_attr = info.external_attr
        zo.writestr(ni, data)
        print(("REPLACED " if info.filename in names else "kept     ") + info.filename)
