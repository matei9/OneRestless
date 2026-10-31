# OneLineage

**NOTE: OneLineage is just a proof of concept, this repo should provide you with enough to port other roms to bootloader locked devices, the lineageos with this repo is just a demo of this capability, and therefore does not fully work. Have fun!**

> ## Galaxy A17 5G / One UI 9 / LineageOS 24.0 fork (`lineage-24.0` branch)
>
> This branch targets the **LineageOS 24.0 (Android 17) Treble GSI** on a bootloader-locked **Galaxy A17 5G**
> running One UI 9, with an optional **MindTheGapps 17** install. The patched framework jars must match the
> staged GSI build; see [PATCHES.md](PATCHES.md) for how to regenerate them.
>
> **Status:** the container and all the A17 port fixes carry over from the RestlessOS work (boot, display with the
> A17 overlay for the cutout / rounded corners / 90 Hz / brightness, touch, audio, camera, Wi-Fi, mobile data,
> internal storage, root (KernelSU), PIN and fingerprint, switching back to One UI). The LineageOS 24.0 jars are
> re-patched from this GSI with the same `tools/patch_smali.py`. The **Install GApps** button downloads MindTheGapps 17
> and overlays its `product` / `system_ext` trees (and the GMS APEX) into the guest — best-effort, still being tested.
>
> **Target GSI:**
> [`lineage-24.0-20261029-UNOFFICIAL-arm64_bvN`](https://github.com/eyzner/LineageOS-GSI/releases/tag/lineage-24.0-20261029),
> on Galaxy A17 5G (SM-A176B, bootloader locked, rooted with KernelSU), One UI 9 (`A176BXXU8DZJ5`).
>
> **⚠️ Do not set any screen lock in One UI** (no PIN, pattern, password or fingerprint). The guest shares the phone's
> security hardware with One UI (Weaver, Gatekeeper, keystore and the fingerprint sensor). A screen lock set in
> the guest can overwrite One UI's, and One UI will then reject its own PIN. Its internal storage can't be decrypted
> again, and the only way back is a factory reset. The guest also deletes fingerprints it didn't enroll itself.
> Set your PIN and fingerprint **only in the guest**.

Hot-switch between stock **One UI** and a **LineageOS 23.2 (Android 16) GSI** on a rooted Samsung phone, with no reflashing and no second partition. OneLineage stages the GSI under `/data/local/tmp`, pivots into it as a container with its own zygote and system_server, and can hand the screen back to One UI.

> ## Disclaimer
> **This has been tested on only a handful of devices, and it seems if you want to install it without making modifications, it has to be on Android 16**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

> Hey, Contributor RealThalesGit here, if you somewhat get throw back to one ui after getting stuck at lineage boot screen, check your manager modules.

## Requirements
- A rooted samsung phone (the tested ones are: S26 Ultra and Samsung A25, both at One UI 8.5.) (Can be temp-root too.)
- Enough free space on `/data` for the extracted GSI
- Internet access for the GSI download (LineageOS 23.2 GSI, EXT4, VANILLA or GAPPS builds from SourceForge)

## What's in here
| Path | What it is |
| --- | --- |
| `src/`, `res/`, `AndroidManifest.xml` | The Android app (`com.wewaffles.onelineage`) |
| `assets/master_prepare.sh` | Stages the rootfs, binds the patched files, fixes labels/ownership |
| `assets/master_inner.sh` | Runs inside the container, starts the guest zygote |
| `assets/switch_to_lineage.sh` / `return_to_oneui.sh` | Switch in and back out |
| `assets/zygote_exec` | Static aarch64 launcher for the guest zygote |
| `build_apk.sh` | Builds and signs the APK |

## Patches

### Patched system files (bind-mounted over the GSI)
- `services_patched.jar` over `system/framework/services.jar`
- `framework_patched.jar` over `system/framework/framework.jar`
- `PermissionController_patched.apk`: removes the `android.permission.RANGING` reference so runtime-permission dialogs stop crashing (Samsung's PermissionController needs a permission the LineageOS 23.2 platform doesn't define)
- Optional bind-mounts when present: `framework-res_patched.apk`, `libaudio_aidl_conversion_common_cpp_patched.so`, `libaudioclient_aidl_conversion_patched.so`

### Boot and environment fixes
1. **APEX paths in the container.** Host `/system/apex` and `/system_ext/apex` are bound into the rootfs after the GSI payloads are extracted, so PackageManagerService stops dying in `scanApexPackages`.
2. **SELinux labels on the staged `/data`.** The tree is relabeled like a real `/data` (`system_data_file`, per-package `app_data_file`) instead of `shell_data_file`. Also `setenforce 0` during the takeover and `setenforce 1` on return.
3. **Audio hang.** Host `audioserver`/`cameraserver` are left running (they used to be stopped/frozen, which deadlocked `AudioService`). Only the host zygote is suppressed.
4. **Runaway `sf.log`.** SurfaceFlinger output goes to `/dev/null` (it was growing to hundreds of MB in minutes).
5. **App data ownership.** `fix_app_dirs.sh` re-owns app data dirs to the uid PackageManager assigned, strips write bits from dex/apk/jar files (ART refuses writable dex), and creates missing dirs such as `/data/misc/bluedroid`.
6. **No installd.** `ensure_app_storage.sh` plus a 15 s sweeper create `/data/user/0`, `/data/user_de/0` and shared-storage dirs for new installs, so apps installed inside Lineage can launch.
7. **Gesture navigation.** Overlay idmaps are generated with `idmap2 --ignore-overlayable` before zygote starts.
8. **Bluetooth crash loop** fixed by creating `/data/misc/bluedroid` before boot.
9. **adb.** `Settings.Global.ADB_ENABLED` is pre-seeded, host `adb_keys` are copied into the guest, and `adb_watchdog.sh` keeps adbd and the USB gadget alive.
10. **Networking.** The preferred APN is switched to `IPV4V6`, and `net_fix.sh` maintains a private routing table (4242) because the guest's ConnectivityService can't program the host's netd.
11. **SMS.** `ims_watchdog.sh` keeps One UI's `imsd` running and `switch_to_lineage.sh` waits for voice registration before pivoting.
12. **Boot diagnostics.** Each boot writes `/data/boot_failures.log`.

## Building
Set `ANDROID_SDK` (or `ANDROID_HOME`) to your Android SDK directory and run `./build_apk.sh`; it writes `build/OneLineage.apk` and creates a development keystore on first use. The build also assembles `svcstub.dex` and the device overlays under `overlay/`. Defaults target build-tools 34.0.0 / android-34, but on a newer JDK (e.g. 27) `d8` from build-tools 34 can crash — pass build-tools 35 instead:

```sh
SDK_TOOLS=$ANDROID_SDK/build-tools/35.0.0 \
PLATFORM_JAR=$ANDROID_SDK/platforms/android-35/android.jar ./build_apk.sh
```

Override `ANDROID_SDK`, `SDK_TOOLS`, `PLATFORM_JAR`, or `OUT_APK` as needed. `EXTRA_ASSETS_DIR` supplies locally-built assets (e.g. jars patched from a license-restricted GSI) that replace same-named files in `assets/` for that build only.

## Credits
OneLineage by WeWaffles. LineageOS 24.0 Treble GSI builds by
[eyzner](https://github.com/eyzner) ([LineageOS-GSI](https://github.com/eyzner/LineageOS-GSI)). MindTheGapps by the MindTheGapps project.
LineageOS GSI builds by MisterZtr (SourceForge). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
