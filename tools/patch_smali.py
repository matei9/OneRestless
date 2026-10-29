#!/usr/bin/env python3
"""Re-apply OneLineage's system_server patches to a freshly decompiled
LineageOS GSI framework.jar / services.jar (apktool d output).

The original project shipped binary-patched jars for LineageOS 23.2 with no
source. This script reproduces every one of those patches *by class and method
name* so they can be re-applied to newer GSIs (LineageOS 24 / Android 17).

usage: patch_smali.py <framework_smali_root> <services_smali_root>
Each root is an apktool output dir containing smali/, smali_classes2/, ...
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

def unknown_flag_is_false(body):
    """Container can't read Android 17 aconfig storage, so getFlagValue() is
    null for every flag; treat unknown as disabled instead of throwing."""
    for i, l in enumerate(body):
        if '"Invalid feature flag: "' in l:
            j = next(k for k in range(i + 1, len(body)) if body[k].strip())
            if body[j].strip().startswith("invoke-static"):
                return body[:j] + body[j + 1:]
    return None

def main(fw, svc):
    print("framework.jar")
    for sig in ["isUserUnlocked()Z", "isUserUnlocked(I)Z",
                "isUserUnlocked(Landroid/os/UserHandle;)Z", "isUserUnlockingOrUnlocked(I)Z"]:
        edit(fw, "android/os/UserManager", sig, stub("0x1"), "always unlocked")
    edit(fw, "android/os/storage/StorageManager", "isCeStorageUnlocked(I)Z", stub("0x1"), "CE always unlocked")
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
    edit(svc, "com/android/server/permission/access/appop/AppOpService", "createPermissionAppOpMapping()V",
         appop_skip_missing_permission, "tolerate missing permission defs")
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

    edit(svc, "com/android/server/security/advancedprotection/AdvancedProtectionConfigLoader",
         "isFeatureFlagEnabled(Ljava/lang/String;)Z", unknown_flag_is_false,
         "unknown aconfig flag -> false (no flag storage in container)")

    print("\nmodified dex dirs:"); [print("  " + t) for t in sorted(TOUCHED)]
    if FAIL:
        print("\nFAILED:"); [print("  " + f) for f in FAIL]; sys.exit(1)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
