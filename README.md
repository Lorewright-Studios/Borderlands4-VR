# Borderlands 4 in VR (UEVR)

A working VR profile for **Borderlands 4** on PC with [UEVR](https://github.com/praydog/UEVR):

- the gun **renders in VR and follows your right hand**, with muzzle flash; swaps re-attach automatically
- **shots go where you point** the right controller
- **firing never moves the camera** (per-shot kick cancelled, camera yaw/roll pinned, position frozen while firing)
- the **ECHO menu** (map, skills, inventory, customization) and the pause menu **work** and show whole in both eyes
- **co-op works** (every player in the session runs the profile)

Tested on Meta Quest 3 over Link (OpenXR), RTX-class GPUs, Borderlands 4 (Steam, UE 5.5).

## Install (fresh PC)

Grab **`Borderlands4-VR_FullInstall_<date>.zip`** from [Releases](../../releases) and follow [INSTALL.txt](INSTALL.txt).
Short version:

1. Copy the `UEVR_AutoInject` folder from the zip somewhere permanent (it contains the launcher and the exact UEVR build).
2. Run `UEVRAutoInject.exe`, press **F7**, import `Borderlands4.zip` from the zip.
3. In the game: **Options → Visuals → Depth of Field = Disabled** (once).
4. Headset runtime running → pick Borderlands 4 → **Play in VR**.

Already have UEVR? You need the **Lorewright UEVR build** (joeyhodge's fork plus one option, see below) — the ECHO menu splits between the eyes on every other build — and the profile zip from Releases, imported with UEVR's "Import Config".

## What's in here

| Path | What |
|---|---|
| `profile/` | The UEVR profile as installed to `%APPDATA%\UnrealVRMod\Borderlands4` (config + scripts + data) |
| `profile/scripts/BL4_GunFix.lua` | Pulls the equipped weapon + FX out of Gearbox's "GbxForeground" render pass (which UEVR cannot draw per eye) and attaches it to the right controller |
| `profile/scripts/BL4_RecoilFix.lua` | Cancels the per-shot control-rotation kick, pins camera yaw/roll, freezes camera position while firing |
| `profile/scripts/CutsceneAndMenuDetection.lua` | Community script + my additions: menu rendering mode switch, startup guard |
| `INSTALL.txt` | Step-by-step install |
| `docs/TECHNICAL.md` | Root causes, what was tried, what failed, engine facts |

## The UEVR build

The profile needs the `VR_2DScreenFullSource` option, which lives in my branch of joeyhodge's fork:
**https://github.com/Lorewright-Studios/UEVR** (branch `bl4-menu-fullsource`). The ECHO menu draws itself once across UEVR's double-wide stereo buffer; this option makes the 2D screen show that whole image to both eyes while the menu is open, with the eyes sized so the menu keeps normal proportions. It is off by default and the script turns it on only while a menu is open. The full-install zip ships a prebuilt copy.

## Known issues

- **Rendering method.** The profile uses *Synchronized Sequential* (each eye rendered as a full frame). *Native Stereo* runs noticeably smoother and is otherwise clean, but loot rarity glows render with the wrong color in one eye. To use it anyway set `gameplayRenderingMethod = "0"` in `CutsceneAndMenuDetection.lua`.
- **Depth of Field must be off** in the game options (magenta bokeh fills one eye otherwise).
- The first-person **arms are hidden on purpose** (showing them caused a right-eye flicker).
- Controllers go to sleep after a pause; press any button to wake them.

## Credits

- [UEVR](https://github.com/praydog/UEVR) by praydog; [joeyhodge's fork](https://github.com/joeyhodge/UEVR) for UE 5.5 support including Borderlands 4's Slate UI path.
- `CutsceneAndMenuDetection.lua` is based on the community script of the same name.
- Launcher: [UEVR Auto Inject](https://github.com/Lorewright-Studios/UEVR-AutoInject), also mine.
- Profile, scripts and the UEVR change: David Grosso (Lorewright Studios).
