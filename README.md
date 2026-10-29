# OneLineage

**NOTE: OneLineage is just a proof of concept, this repo should provide you with enough to port other roms to bootloader locked devices, the lineageos with this repo is just a demo of this capability, and therefore does not fully work. Have fun!**

> ## Galaxy A17 5G / One UI 9 / RestlessOS fork
>
> This fork targets the **RestlessOS (Android 17) GSI** on a bootloader-locked **Galaxy A17 5G** running One UI 9.
> It builds on Dylan's One UI 9 / RestlessOS port (`restlessos` branch). The patched framework jars must match the
> staged GSI build; see [PATCHES.md](PATCHES.md) for how to regenerate them.
>
> **Status: basically usable.** All the main functions work: boot, display (with an A17 overlay for the cutout,
> rounded corners, 90 Hz and brightness), touch, audio, camera, Wi-Fi, mobile data, internal storage, root
> (KernelSU) inside RestlessOS, PIN and fingerprint in RestlessOS, and switching back to One UI.
>
> **Tested on:** Galaxy A17 5G (SM-A176B, bootloader locked, rooted with KernelSU), One UI 9
> (`A176BXXU8DZJ5`), with the RestlessOS GSI
> [`RestlessOS-arm64-ab-17.0.0-202610280533`](https://github.com/cawilliamson/treble_restlessos/releases/tag/17.0.0-202610280533).
>
> **⚠️ Do not set any screen lock in One UI** (no PIN, pattern, password or fingerprint). RestlessOS shares the phone's
> security hardware with One UI (Weaver, Gatekeeper, keystore and the fingerprint sensor). A screen lock set in
> RestlessOS can overwrite One UI's, and One UI will then reject its own PIN. Its internal storage can't be decrypted
> again, and the only way back is a factory reset. RestlessOS also deletes fingerprints it didn't enroll itself.
> Set your PIN and fingerprint **only in RestlessOS**.

Hot-switch between stock **One UI** and a **LineageOS 23.2 (Android 16) GSI** on a rooted Samsung phone, with no reflashing and no second partition. OneLineage stages the GSI under `/data/local/tmp`, pivots into it as a container with its own zygote and system_server, and can hand the screen back to One UI.

> ## Disclaimer
> **This has been tested on only a handful of devices, and it seems if you want to install it without making modifications, it has to be on Android 16**
> It may not work on other Samsung models, other One UI versions, or other devices at all. It is experimental, it replaces core parts of a running system, and it can crash, hang or soft-brick your phone, fill `/data`, or break radio/SMS. **Back up everything first. Use at your own risk.**
> Also, I did use AI a fair bit in this project, it would have taken a LOT longer without it.

## Requirements
- A rooted Samsung phone (the tested one is an S26 Ultra on One UI 8.5)
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
Edit the paths at the top of `build_apk.sh` (JDK 17, Android SDK build-tools 34, android-34 platform), provide your own signing keystore, then run `./build_apk.sh`.

## Credits
LineageOS GSI builds by MisterZtr (SourceForge). RestlessOS Treble GSI builds by
[cawilliamson](https://github.com/cawilliamson) ([treble_restlessos](https://github.com/cawilliamson/treble_restlessos)). LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google or LineageOS.
