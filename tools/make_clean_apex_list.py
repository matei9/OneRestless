#!/usr/bin/env python3
"""make_clean_apex_list.py <host apex-info-list.xml> <out.xml>

Build assets/clean_apex_info_list.xml from `adb shell su -c cat /apex/apex-info-list.xml`.
The container's PackageManager parses every modulePath in this list, and
/dev/block/dm-* paths (updated APEXes mounted by host apexd) don't exist inside
the pivoted rootfs. So: one entry per module, taken from its *factory*
(preinstalled) entry, marked active - every path then lives under the host's
/system/apex, /system_ext/apex or /vendor/apex, which are bind-mounted in."""
import sys, xml.etree.ElementTree as ET
src, out = sys.argv[1], sys.argv[2]
mods = {}
for e in ET.parse(src).getroot().iter("apex-info"):
    a = dict(e.attrib); name = a["moduleName"]
    if a.get("isFactory") == "true":
        mods[name] = a                      # factory entry wins
    elif name not in mods and not a["modulePath"].startswith("/dev/"):
        mods[name] = a
root = ET.Element("apex-info-list")
for name, a in mods.items():
    a["isActive"] = "true"
    a["modulePath"] = a["preinstalledModulePath"]
    ET.SubElement(root, "apex-info", a)
ET.indent(root, "  ")
ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
print(f"{len(mods)} modules -> {out}")
