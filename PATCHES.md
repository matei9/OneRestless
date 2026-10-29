# System patches (Android 17 / LineageOS 24 port)

The original project shipped `services_patched.jar` and `framework_patched.jar` as
binary-patched blobs for the LineageOS 23.2 GSI, with no source. On this branch they
were reverse-engineered (diffed against the stock `LineageOS-23.2-20260524-VANILLA-EXT4`
jars) and re-implemented as a script, `tools/patch_smali.py`, that applies each patch
by class and method name, so it can be re-run against new GSI builds.

Target GSI: `lineage-24.0-20261016-UNOFFICIAL-arm64-gsi` (ods-releases), build
`CP2A.260605.016`, SDK 37, EXT4. That build ID matches the Galaxy Z Fold 8
(SM-F971U, One UI 9, `CP2A.260605.016.F971USQS3AZIL`). This matters because the
container runs the GSI framework against the host's APEX modules.

## Why these patches exist
The guest system_server runs in a pivot_root container with no vold, FBE, installd,
USB/adb ownership, or the ability to reboot the phone. Every patch stubs out one of
those dependencies.

| Jar | Class -> method | Change |
|---|---|---|
| framework | `UserManager.isUserUnlocked()`, `(I)`, `(UserHandle)`, `isUserUnlockingOrUnlocked(I)` | return `true` |
| framework | `StorageManager.isCeStorageUnlocked(I)` | return `true` |
| framework | `IAuthenticationPolicyService$Stub.*SecureLockDevice*_enforcePermission()` (6) | no-op |
| services | `Watchdog.run()` | never `killProcess`/`System.exit` system_server |
| services | `StorageManagerService.isCeStorageUnlocked(I)` | return `true` |
| services | `StorageManagerService$StorageManagerInternalImpl.setCeStorageProtection` | no-op (no vold) |
| services | `...InternalImpl.unlockCeStorage` | skip vold call, still mark user unlocked |
| services | `SystemServer.startApexServices` | don't start services that live in APEX jars |
| services | `AdbService$Lifecycle.onBootPhase` | no-op (host owns adbd) |
| services | `UsbService$Lifecycle.onBootPhase` | no-op (host owns USB gadget) |
| services | `UserController.maybeUnlockUser(I,IProgressListener)` | allow unlock before boot completes |
| services | `KeyGestureController.handleMessage` | screenshot msg tolerates `obj == null` (uses arg1/arg2) |
| services | `LockSettingsService.initKeystoreSuperKeys` | ignore keystore super-key failure |
| services | `LockSettingsService.setCeStorageProtection` | no-op |
| services | `AppOpService.createPermissionAppOpMapping` | skip ops whose permission is undefined instead of throwing |
| services | `UserDataPreparer.prepareUserData`, `prepareUserDataLI` | no-op (no installd/vold) |
| services | `PowerManagerService.lowLevelReboot` | no-op (guest must not reboot the phone) |
| services | `AdvancedProtectionConfigLoader.isFeatureFlagEnabled` | unknown aconfig flag -> `false` instead of throwing (Android 17 flag storage isn't readable in the container) |

Only the modified dex files are replaced (`services`: classes, classes2, classes3;
`framework`: classes3). All other entries are byte-identical to the GSI.

**PermissionController patch dropped.** On 23.2, `android.permission.RANGING` was gated
behind a disabled feature flag, so the host's PermissionController crashed. LineageOS 24
defines it unconditionally. The old patched APK was also built from an S26/Android 16
PermissionController, which is the wrong version for an Android 17 host.

## Rebuilding for a new GSI
```sh
# 1. pull jars from the GSI system.img (ext4)
debugfs -R "dump /system/framework/services.jar  services.jar"  system.img
debugfs -R "dump /system/framework/framework.jar framework.jar" system.img
# 2. decompile (apktool 3.x)
java -jar apktool.jar d -f -o svc services.jar
java -jar apktool.jar d -f -o fw  framework.jar
# 3. patch (fails loudly if any method moved)
python3 tools/patch_smali.py fw svc
# 4. reassemble, then graft only the touched dex files back into the stock jars
java -jar apktool.jar b -o svc_built.jar svc
java -jar apktool.jar b -o fw_built.jar  fw
python3 tools/graft_dex.py services.jar  svc_built.jar assets/services_patched.jar  classes.dex classes2.dex classes3.dex
python3 tools/graft_dex.py framework.jar fw_built.jar  assets/framework_patched.jar classes3.dex
# 5. per-device apex list
adb shell su -c "cat /apex/apex-info-list.xml" > apex-info-list.xml
python3 tools/make_clean_apex_list.py apex-info-list.xml assets/clean_apex_info_list.xml
```

## zygote_exec classpaths
`assets/zygote_exec` is a ~130-instruction hand-written aarch64 binary. It creates the
zygote/usap sockets on fds 3/4, sends stdio to /dev/null, and `execve`s `app_process64`
with a **fixed** environment, including `BOOTCLASSPATH` and `SYSTEMSERVERCLASSPATH`.
The 23.2 lists are missing Android 17 jars (`framework-telecom`, `framework-conscrypt-nsc`,
`framework-npumanager`, `framework-anomaly-detector`, `framework-uprobestats`,
`framework-webapp`, `service-telecom`, `service-npumanager`, `service-anomaly-detector`,
`service-uprobestats-bridge`). That made zygote die in preload with
`NoClassDefFoundError` in `SystemServiceRegistry`, leaving the phone stuck on the boot animation.

`tools/build_zygote_exec.py` rewrites only the environment table, from
`tools/zygote_classpath_lineage24.env` (derived from the GSI's `etc/classpaths/*.pb`
fragments). It re-encodes the one `adr x2, envp` and fixes the PT_LOAD size. Under
emulation, the rebuilt binary makes the same syscalls as the original apart from
the classpath strings. Before launching, `master_inner.sh` now logs any classpath
jar missing from the container.

## Runtime classpaths (any GSI)
`zygote_exec` is now built with `tools/build_zygote_exec.py --inherit-env`: the one
`adr x2, envp` becomes a branch to a 4-instruction stub that passes the caller's
environment to `execve`. `master_inner.sh` runs the mounted sdkext APEX's
`derive_classpath` inside the container, as init does on a real boot. It then
launches zygote with `env -i` plus the derived `BOOTCLASSPATH`,
`SYSTEMSERVERCLASSPATH` and related variables. The classpaths always match the
system image and APEX mix actually mounted. `assets/zygote_classpath.env` is only
a fallback.

## Google GSI (gsi_gms_arm64)
Google's Android 17 GSI (`CP2A.260605.012`) ships Google-signed mainline modules,
matching the host's, so the host's tethering APEX can be used without the
networkstack signature conflict hit with LineageOS. `patch_smali.py` applies
unchanged; the KeyGestureController screenshot patch reports "not needed".
**The GMS GSI license forbids modifying or redistributing it.** Jars patched from it
are built locally into `../google-gsi-overlay/` and passed to `build_apk.sh` via
`EXTRA_ASSETS_DIR`. They are never committed. `mount_payload` now accepts Google's
`com.google.android.<name>.apex` naming (compressed or not), and the payload cache
is cleared whenever `system.raw` changes.
