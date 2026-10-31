#!/usr/bin/env python3
"""Re-apply OneLineage's system_server patches to a freshly decompiled
LineageOS GSI framework.jar / services.jar (apktool d output).

The original project shipped binary-patched jars for LineageOS 23.2 with no
source. This script reproduces every one of those patches *by class and method
name* so they can be re-applied to newer GSIs (LineageOS 24 / Android 17).

usage: patch_smali.py <framework_smali_root> <services_smali_root> [<host_framework_smali_root>]
Each root is an apktool output dir containing smali/, smali_classes2/, ...
With the host's (One UI's) framework.jar decompiled as the third root, the
binder interfaces shared with Samsung's native daemons are renumbered to the
host's transaction codes (see HOST_ALIGNED_INTERFACES).
Prints which dex dir each patched class lives in; exits non-zero on any miss.
"""
import glob, os, re, sys

FAIL = []
TOUCHED = set()

def find_class(root, cls):
    hits = glob.glob(os.path.join(root, "smali*", cls + ".smali"))
    if len(hits) != 1:
        FAIL.append(f"class {cls}: {len(hits)} matches"); return None
    return hits[0]

def method_span(lines, sig):
    """Return (start, end) line indices of the .method whose header ends with sig."""
    for i, l in enumerate(lines):
        if l.startswith(".method") and l.rstrip().endswith(" " + sig) or (l.startswith(".method") and l.rstrip().split(" ")[-1] == sig):
            for j in range(i, len(lines)):
                if lines[j].startswith(".end method"):
                    return i, j
    return None

def edit(root, cls, sig, fn, desc):
    path = find_class(root, cls)
    if not path: return
    lines = open(path, encoding="utf-8").read().split("\n")
    span = method_span(lines, sig)
    if not span:
        FAIL.append(f"{cls}->{sig}: method not found"); return
    s, e = span
    body = lines[s + 1:e]
    new = fn(body)
    if new == "SKIP":
        print(f"  --  {cls}->{sig}  [{desc}: not needed in this build]"); return
    if new is None:
        FAIL.append(f"{cls}->{sig}: pattern not found ({desc})"); return
    lines[s + 1:e] = new
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    TOUCHED.add(os.path.relpath(path, root).split(os.sep)[0] + "  " + root)
    print(f"  ok  {cls}->{sig}  [{desc}]")

# ---- generic transforms -------------------------------------------------
def keep_directives(body):
    """Keep .annotation/.param blocks (metadata), drop all code."""
    out, depth = [], 0
    for l in body:
        t = l.strip()
        if t.startswith(".annotation") or t.startswith(".param"):
            # single-line .param has no .end param
            if t.startswith(".annotation"): depth += 1
            out.append(l); continue
        if depth:
            out.append(l)
            if t.startswith(".end annotation"): depth -= 1
            continue
        if t.startswith(".end param"): out.append(l)
    return out

def stub(ret):
    def fn(body):
        meta = keep_directives(body)
        if ret == "void":
            code = ["    .locals 0", "", "    return-void"]
        else:
            code = ["    .locals 1", "", f"    const/4 v0, {ret}", "", "    return v0"]
        return code[:1] + meta + code[1:]
    return fn

def insert_after(pattern, new_line_fn, nth_after=1):
    """Insert a line after the first line matching pattern (+ following move-result)."""
    rx = re.compile(pattern)
    def fn(body):
        for i, l in enumerate(body):
            if rx.search(l):
                j = i
                # skip blank lines to the move-result if requested
                if nth_after == 2:
                    j = next(k for k in range(i + 1, len(body)) if body[k].strip())
                m = re.match(r"\s*\S+\s+([vp]\d+)", body[j])
                reg = m.group(1) if m else None
                return body[:j + 1] + ["", new_line_fn(reg, l)] + body[j + 1:]
        return None
    return fn

def delete_lines(*patterns):
    rxs = [re.compile(p) for p in patterns]
    def fn(body):
        out, n = [], 0
        for l in body:
            if any(r.search(l) for r in rxs): n += 1; continue
            out.append(l)
        return out if n else None
    return fn

# ---- bespoke transforms -------------------------------------------------
def appop_skip_missing_permission(body):
    """Missing permission definition -> skip that op instead of throwing."""
    s = next((i for i, l in enumerate(body) if "Missing permission definition" in l), None)
    if s is None: return None
    lbl = next((body[i].strip() for i in range(s, -1, -1) if body[i].strip().startswith(":cond_")), None)
    thr = next((i for i in range(s, len(body)) if body[i].strip().startswith("throw ")), None)
    cont = next((body[i].strip() for i in range(thr, len(body)) if body[i].strip().startswith(":")), None)
    if not (lbl and cont): return None
    n = 0
    out = []
    for l in body:
        if re.search(r"^\s*if-\S+ .*, " + re.escape(lbl) + r"$", l):
            l = l[: l.rfind(lbl)] + cont; n += 1
        out.append(l)
    return out if n else None

def screenshot_null_obj(body):
    """MSG 5 (take screenshot) may arrive with obj==null: use arg1/arg2."""
    TSD = "Lcom/android/server/input/KeyGestureController$TakeScreenshotData;"
    if not any(TSD in l for l in body):
        return "SKIP"      # build already passes source/type via arg1/arg2
    for i, l in enumerate(body):
        if l.strip() == f"check-cast p1, {TSD}":
            k = max(j for j in range(i) if body[j].strip())
            if body[k].strip() != "iget-object p1, p1, Landroid/os/Message;->obj:Ljava/lang/Object;":
                return None
            repl = [
                "    iget-object v0, p1, Landroid/os/Message;->obj:Ljava/lang/Object;",
                "    if-nez v0, :ol_tsd_nonnull",
                "    const/4 v0, 0x1",
                "    iget v2, p1, Landroid/os/Message;->arg1:I",
                "    if-nez v2, :ol_tsd_type",
                "    const/4 v2, 0x1",
                "    :ol_tsd_type",
                "    iget p1, p1, Landroid/os/Message;->arg2:I",
                "    invoke-virtual {p0, v0, v2, p1}, Lcom/android/server/input/KeyGestureController;->takeScreenshot(III)V",
                "    goto :goto_0",
                "    :ol_tsd_nonnull",
                "    move-object p1, v0",
                f"    check-cast p1, {TSD}",
            ]
            return body[:k] + repl + body[i + 1:]
    return None

def weaver_slots_from_top(body):
    """Hand out Weaver slots from the highest one down instead of from 0 up."""
    WC = "Lcom/android/server/locksettings/SyntheticPasswordManager;->mWeaverConfig:Landroid/hardware/weaver/WeaverConfig;"
    SLOTS = "Landroid/hardware/weaver/WeaverConfig;->slots:I"
    t = [l.strip() for l in body]
    try:
        init = t.index("move v2, v1")
        cond = t.index("if-ge v2, v3, :cond_2")
        step = t.index("add-int/lit8 v2, v2, 0x1")
    except ValueError:
        return None
    prev = [k for k in range(cond - 1, -1, -1) if t[k]][:2]
    if len(prev) < 2 or t[prev[1]] != f"iget-object v3, p0, {WC}" or t[prev[0]] != f"iget v3, v3, {SLOTS}":
        return None
    out = list(body)
    out[step] = "    add-int/lit8 v2, v2, -0x1"
    out[prev[1]:cond + 1] = ["    if-ltz v2, :cond_2"]
    out[init:init + 1] = [f"    iget-object v2, p0, {WC}", f"    iget v2, v2, {SLOTS}",
                          "    add-int/lit8 v2, v2, -0x1"]
    return out

def pm_build_own_permissionmgr(body):
    """PermissionManagerService.create() does getService("permissionmgr") and
    check-casts the result to the local PermissionManagerService. In the
    container the guest shares the host's servicemanager, so it gets the HOST's
    binder proxy and the cast throws ClassCastException, killing system_server.
    Replace the getService + check-cast with null so the guest always builds and
    registers its own permissionmgr."""
    for i, l in enumerate(body):
        if "check-cast" in l and l.rstrip().endswith("Lcom/android/server/pm/permission/PermissionManagerService;"):
            m = re.match(r"\s*check-cast (v\d+|p\d+),", l)
            if not m:
                continue
            reg = m.group(1)
            j = i - 1
            while j >= 0 and not body[j].strip():
                j -= 1
            if j < 0 or not re.match(r"\s*move-result-object " + reg + r"\b", body[j]):
                continue
            k = j - 1
            while k >= 0 and not body[k].strip():
                k -= 1
            if k < 0 or "ServiceManager;->getService(" not in body[k]:
                continue
            indent = re.match(r"(\s*)", body[k]).group(1)
            return body[:k] + [indent + "const/4 " + reg + ", 0x0"] + body[i + 1:]
    return None

def unknown_flag_is_false(body):
    """Container can't read Android 17 aconfig storage, so getFlagValue() is
    null for every flag; treat unknown as disabled instead of throwing."""
    for i, l in enumerate(body):
        if '"Invalid feature flag: "' in l:
            j = next(k for k in range(i + 1, len(body)) if body[k].strip())
            if body[j].strip().startswith("invoke-static"):
                return body[:j] + body[j + 1:]
    return None


def torch_skips_logical_cameras(body):
    """SystemUI's flashlight picks the first back camera with a flash that has
    physical cameras, then falls back to any. Samsung lists its private logical
    camera 23, which claims a flash but cameraserver refuses torch on ("does not
    have a flash unit"), so the tile stays unavailable. Show SystemUI no physical
    cameras and it lands on camera 0; other apps still see the logical cameras."""
    i = next((k for k, l in enumerate(body) if l.strip().startswith(".line")), None)
    if i is None or body[0].strip() != ".locals 1":
        return None
    return [body[0].replace("1", "2")] + body[1:i] + [
        "    invoke-static {}, Landroid/app/ActivityThread;->currentPackageName()Ljava/lang/String;",
        "    move-result-object v0",
        '    const-string v1, "com.android.systemui"',
        "    invoke-virtual {v1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z",
        "    move-result v0",
        "    if-eqz v0, :not_systemui",
        "    invoke-static {}, Ljava/util/Collections;->emptySet()Ljava/util/Set;",
        "    move-result-object v0",
        "    return-object v0",
        "    :not_systemui",
    ] + body[i:]


# ---- align binder transaction codes with the host -----------------------
# The guest's apps talk straight to the HOST's native daemons (cameraserver,
# audioserver, ...), and those call back into the guest's system_server. Samsung
# inserts methods into the middle of some AIDL interfaces, which shifts every
# later transaction code, so the guest ends up calling (or serving) the wrong
# method: e.g. ICameraDeviceUser.getCaptureResultMetadataQueue (23) lands on
# Samsung's finalizeOutputConfigurations and camera open dies with
# "ParcelFormatException: Not enough data".
# Fix: guest Proxies send the host's codes, and guest Stubs translate host codes
# back to their own methods at the top of onTransact. Every guest process loads
# the same patched framework.jar, so guest<->guest calls stay consistent.
HOST_ALIGNED_INTERFACES = [
    "android/hardware/ICameraService",              # guest -> host cameraserver
    "android/hardware/camera2/ICameraDeviceUser",   # guest -> host cameraserver
    "android/hardware/ISensorPrivacyManager",       # host cameraserver -> guest
]
INVALID_CODE = "0xfffffe"  # inside FIRST..LAST_CALL_TRANSACTION, never a method

def transaction_table(root, iface):
    hits = glob.glob(os.path.join(root, "smali*", iface + "$Stub.smali"))
    if len(hits) != 1:
        return None
    return {m.group(1): int(m.group(2), 16) for m in re.finditer(
        r"\.field [^\n]*?TRANSACTION_(\w+):I = (0x[0-9a-f]+)", open(hits[0], encoding="utf-8").read())}

def align_to_host(fw, host, iface):
    g, h = transaction_table(fw, iface), transaction_table(host, iface)
    if g is None or h is None:
        FAIL.append(f"{iface}: Stub not found (guest={g is not None}, host={h is not None})"); return
    missing = sorted(set(g) - set(h))
    if missing:
        FAIL.append(f"{iface}: guest-only methods {missing}, can't adopt host numbering"); return
    if all(g[n] == h[n] for n in g) and len(h) == len(g):
        print(f"  --  {iface}  [already matches host]"); return

    # Proxy: rewrite the code constant that feeds each IBinder.transact().
    path = find_class(fw, iface + "$Stub$Proxy")
    if not path: return
    lines = open(path, encoding="utf-8").read().split("\n")
    i, method, done = 0, None, 0
    while i < len(lines):
        l = lines[i]
        if l.startswith(".method"):
            method = l.split(" ")[-1].split("(")[0]
        m = re.match(r"\s*invoke-interface(/range)? \{([^}]*)\}, Landroid/os/IBinder;->transact\(", l)
        if m and method in g and g[method] != h[method]:
            regs = m.group(2)
            if m.group(1):
                a, b = [r.strip() for r in regs.split("..")]
                code_reg = a[0] + str(int(a[1:]) + 1)
            else:
                code_reg = regs.split(",")[1].strip()
            for j in range(i - 1, -1, -1):
                c = re.match(r"(\s*)const(/4|/16)? " + re.escape(code_reg) + r", (-?0x[0-9a-f]+)$", lines[j])
                if c:
                    if int(c.group(3), 16) != g[method]:
                        FAIL.append(f"{iface}.Proxy.{method}: code const {c.group(3)} != {g[method]}"); break
                    lines[j] = f"{c.group(1)}const/16 {code_reg}, {hex(h[method])}"
                    done += 1; break
                if lines[j].startswith(".method"):
                    FAIL.append(f"{iface}.Proxy.{method}: code const not found"); break
        i += 1
    open(path, "w", encoding="utf-8").write("\n".join(lines))
    TOUCHED.add(os.path.relpath(path, fw).split(os.sep)[0] + "  " + fw)

    # Stub: translate host codes to guest codes before the guest's own dispatch.
    by_host = {v: n for n, v in h.items()}
    remap = {hc: (hex(g[n]) if n in g else INVALID_CODE) for hc, n in by_host.items()
             if n not in g or g[n] != hc}
    def prologue(body):
        at = next(k for k, l in enumerate(body) if l.strip().startswith(".locals"))
        code = ["", "    sparse-switch p1, :ol_host_codes", "    goto :ol_host_codes_done"]
        for k, (hc, gc) in enumerate(sorted(remap.items())):
            code += [f"    :ol_host_{k}", f"    const p1, {gc}", "    goto :ol_host_codes_done"]
        code += ["    :ol_host_codes_done"]
        table = ["", "    :ol_host_codes", "    .sparse-switch"]
        table += [f"        {hex(hc)} -> :ol_host_{k}" for k, (hc, gc) in enumerate(sorted(remap.items()))]
        table += ["    .end sparse-switch"]
        return body[:at + 1] + code + body[at + 1:] + table
    edit(fw, iface + "$Stub", "onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z", prologue,
         f"accept host codes ({len(remap)} remapped)")
    print(f"  ok  {iface}$Stub$Proxy  [{done} calls renumbered to host codes]")

def main(fw, svc, host=None):
    print("framework.jar")
    for sig in ["isUserUnlocked()Z", "isUserUnlocked(I)Z",
                "isUserUnlocked(Landroid/os/UserHandle;)Z", "isUserUnlockingOrUnlocked(I)Z"]:
        edit(fw, "android/os/UserManager", sig, stub("0x1"), "always unlocked")
    edit(fw, "android/os/storage/StorageManager", "isCeStorageUnlocked(I)Z", stub("0x1"), "CE always unlocked")
    # Samsung's audioserver lists a port the GSI can't convert, so listAudioPorts
    # always fails, and every process using AudioManager retried it every 100 ms
    # forever: constant binder traffic into audioserver and ~40 log lines a second.
    edit(fw, "android/media/AudioPortEventHandler$1", "handleMessage(Landroid/os/Message;)V",
         delete_lines(r"->sendMessageDelayed\("), "no endless audio port retry")
    edit(fw, "android/hardware/camera2/CameraCharacteristics", "getPhysicalCameraIds()Ljava/util/Set;",
         torch_skips_logical_cameras, "flashlight tile uses camera 0")
    for n in ["disable", "enable", "getSecureLockDeviceAvailability", "isSecureLockDeviceEnabled",
              "registerSecureLockDeviceStatusListener", "unregisterSecureLockDeviceStatusListener"]:
        sig = (n + "SecureLockDevice" if n in ("disable", "enable") else n) + "_enforcePermission()V"
        edit(fw, "android/security/authenticationpolicy/IAuthenticationPolicyService$Stub", sig,
             stub("void"), "skip permission enforce")

    print("services.jar")
    edit(svc, "com/android/server/Watchdog", "run()V",
         delete_lines(r"Landroid/os/Process;->killProcess\(I\)V", r"Ljava/lang/System;->exit\(I\)V"),
         "never kill system_server")
    edit(svc, "com/android/server/StorageManagerService", "isCeStorageUnlocked(I)Z", stub("0x1"), "CE unlocked")
    edit(svc, "com/android/server/StorageManagerService$StorageManagerInternalImpl",
         "setCeStorageProtection(I[B)V", stub("void"), "no vold")
    edit(svc, "com/android/server/StorageManagerService$StorageManagerInternalImpl", "unlockCeStorage(I[B)V",
         insert_after(r"StorageManager;->isFileEncrypted\(\)Z", lambda r, l: f"    const/4 {r}, 0x0", 2),
         "skip vold unlock, still mark unlocked")
    edit(svc, "com/android/server/SystemServer", "startApexServices(Lcom/android/server/utils/TimingsTraceAndSlog;)V",
         delete_lines(r"SystemServiceManager;->startServiceFromJar\("), "don't start APEX jar services")
    edit(svc, "com/android/server/adb/AdbService$Lifecycle", "onBootPhase(I)V", stub("void"), "host owns adb")
    edit(svc, "com/android/server/am/UserController", "maybeUnlockUser(ILandroid/os/IProgressListener;)Z",
         insert_after(r"UserController;->mAllowUserUnlocking:Z", lambda r, l: f"    const/4 {r}, 0x1"),
         "allow unlock before boot completed")
    edit(svc, "com/android/server/input/KeyGestureController", "handleMessage(Landroid/os/Message;)Z",
         screenshot_null_obj, "screenshot msg null obj")
    edit(svc, "com/android/server/locksettings/LockSettingsService",
         "initKeystoreSuperKeys(ILcom/android/server/locksettings/SyntheticPasswordManager$SyntheticPassword;Z)V",
         insert_after(r"AndroidKeyStoreMaintenance;->initUserSuperKeys\(", lambda r, l: f"    const/4 {r}, 0x0", 2),
         "ignore keystore super key failure")
    edit(svc, "com/android/server/locksettings/LockSettingsService",
         "setCeStorageProtection(ILcom/android/server/locksettings/SyntheticPasswordManager$SyntheticPassword;)V",
         stub("void"), "no CE protection")

    # Weaver is the HOST's secure element. The guest's lock-settings records
    # live in the staged /data, so it believes every Weaver slot is free: a PIN
    # set in the guest took slot 1, overwrote One UI's PIN secret in it, and the
    # One UI PIN was rejected from then on (CE storage lost). One UI allocates
    # from slot 0 up, so the guest allocates from the top slot down. This only
    # separates the two while neither fills the slots; Gatekeeper, keystore2
    # and the fingerprint sensor's templates for user 0 are still shared.
    edit(svc, "com/android/server/locksettings/SyntheticPasswordManager",
         "getNextAvailableWeaverSlot()I", weaver_slots_from_top,
         "guest takes Weaver slots from the top down")
    edit(svc, "com/android/server/permission/access/appop/AppOpService", "createPermissionAppOpMapping()V",
         appop_skip_missing_permission, "tolerate missing permission defs")
    edit(svc, "com/android/server/pm/permission/PermissionManagerService",
         "create(Landroid/content/Context;Landroid/util/ArrayMap;)Lcom/android/server/pm/permission/PermissionManagerServiceInternal;",
         pm_build_own_permissionmgr, "build own permissionmgr, not the host's proxy")
    edit(svc, "com/android/server/pm/UserDataPreparer", "prepareUserData(Landroid/content/pm/UserInfo;I)V",
         stub("void"), "no installd/vold")
    edit(svc, "com/android/server/pm/UserDataPreparer", "prepareUserDataLI(Ljava/lang/String;Landroid/content/pm/UserInfo;IZ)V",
         stub("void"), "no installd/vold")
    edit(svc, "com/android/server/usb/UsbService$Lifecycle", "onBootPhase(I)V", stub("void"), "host owns USB")
    edit(svc, "com/android/server/power/PowerManagerService", "lowLevelReboot(Ljava/lang/String;)V",
         stub("void"), "guest can't reboot the phone")

    # Boot-time dexopt calls into artd via binder (/apex/com.android.art/bin/artd),
    # but the container never starts artd, so every single system package NPEs in
    # ArtService.PrimaryDexopter.maybeCreateSdc and the SystemServer main thread
    # sits in Watchdog.pauseForReason("dexopt") iterating thousands of packages.
    # Skip the upgrade dexopt pass entirely; apps run interpreted (same as a
    # first-boot before dexopt completes), the boot proceeds to phase 400+.
    edit(svc, "com/android/server/pm/DexOptHelper", "performPackageDexOptUpgradeIfNeeded()V",
         stub("void"), "skip boot dexopt (no artd in container)")

    # AppDataHelper.prepareAppDataPostCommitLIF calls SMS.prepareAppDataAfterInstall
    # which calls IVold.fixupAppDir. The guest's vold has no idea about our bound
    # /data/media/0 (not an emulated vold volume), so fixupAppDir returns -22 EINVAL
    # and every install logs:
    #   E StorageManagerService: Failed to fixup app dir for <pkg>
    #   android.os.ServiceSpecificException: (code -22)
    # ensure_app_storage.sh creates /data/media/0/Android/data|media|obb/<pkg> with
    # the right ext_data_rw gid in the background, so this call isn't carrying its
    # weight for us. Stub it to void.
    edit(svc, "com/android/server/StorageManagerService", "fixupAppDir(Ljava/lang/String;)V",
         stub("void"), "ensure_app_storage.sh owns the per-app ext dir setup")

    # AMS.finishBooting -> ZygoteProcess.bootCompleted() opens a client socket to
    # /dev/socket/zygote to tell zygote to leave preload mode. In our pivoted
    # container, the GSI's zygote wires its socket onto fd 3 from zygote_exec but
    # doesn't bind it in the filesystem (init.rc normally does the bind, and we
    # don't run init). The connect fails with ENOENT; the resulting
    # RuntimeException propagates out of WMS.performEnableScreen on the
    # android.display handler thread and kills system_server right before
    # BOOT_COMPLETED broadcasts. Stubbing the public entry makes finishBooting
    # proceed; apps are already spawning fine from fd 3 and this call only
    # signals zygote to drop its lazy-boot heuristics.
    edit(fw, "android/os/ZygoteProcess", "bootCompleted()V",
         stub("void"), "zygote socket not bound to fs path in container")

    # The userdata checkpoint belongs to the host. AMS.finishBooting calls
    # SMS.commitChanges() -> vold; in the container that lands on the guest's
    # vold, fails, and AMS asks for a reboot ("Checkpoint commit failed"). With
    # lowLevelReboot stubbed, ShutdownThread falls through to lowLevelShutdown and
    # powers the phone off (Samsung: "reboot,lpm" when charging). abortChanges is
    # vold's "roll back and reboot". The guest must never touch either.
    edit(svc, "com/android/server/StorageManagerService", "commitChanges()V",
         stub("void"), "host owns the userdata checkpoint")
    edit(svc, "com/android/server/StorageManagerService", "abortChanges(Ljava/lang/String;Z)V",
         stub("void"), "host owns the userdata checkpoint")
    edit(svc, "com/android/server/StorageManagerService", "needsCheckpoint()Z",
         stub("0x0"), "host owns the userdata checkpoint")

    # GrapheneOS-derived GSIs carry PackageVerityExt, which throws if an updated
    # system package has the same versionCode as the system image copy. The
    # container scans the host's APEXes through the host apexd, and the host's
    # decompressed compressed-APEXes (adservices, ondevicepersonalization,
    # crashrecovery on /dev/block/dm-*) always have the same versionCode as their
    # factory copy, so PMS dies in scanApexPackages ("Failed to scan:
    # /dev/block/dm-74"). The only escape hatch needs a debuggable build.
    # Not present on non-GrapheneOS-derived GSIs.
    if glob.glob(os.path.join(svc, "smali*", "com/android/server/pm/PackageVerityExt.smali")):
        edit(svc, "com/android/server/pm/PackageVerityExt",
             "checkSystemPackageUpdate(Lcom/android/server/pm/pkg/AndroidPackage;)V",
             stub("void"), "host APEX updates share the factory versionCode")

    edit(svc, "com/android/server/security/advancedprotection/AdvancedProtectionConfigLoader",
         "isFeatureFlagEnabled(Ljava/lang/String;)Z", unknown_flag_is_false,
         "unknown aconfig flag -> false (no flag storage in container)")

    if host:
        print("host-aligned binder interfaces")
        for iface in HOST_ALIGNED_INTERFACES:
            align_to_host(fw, host, iface)

    print("\nmodified dex dirs:"); [print("  " + t) for t in sorted(TOUCHED)]
    if FAIL:
        print("\nFAILED:"); [print("  " + f) for f in FAIL]; sys.exit(1)

if __name__ == "__main__":
    main(*sys.argv[1:4])
