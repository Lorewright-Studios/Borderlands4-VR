# Technical notes — Borderlands 4 + UEVR

Collected while building the profile (Oct 31 – Nov 3, 2026). Setup: joeyhodge UEVR fork (UE 5.5 support, BL4 Slate UI routing), OpenXR, Meta Quest 3.

## Invisible gun / arms → Gearbox's `GbxForeground` pass
Borderlands 4 does **not** use Epic's UE 5.5 first-person primitive system (`bUseFirstPersonParameters=false`, zero components flagged). Gearbox's engine renders arms, weapon and muzzle FX in its own `GbxForeground` pass with a second projection matrix (`GbxForegroundProjectionMatrix`, +0x1E0 in the view init data). UEVR never rewrites that matrix per eye, so the pass never lands in the eye buffers.

Fix (`BL4_GunFix.lua`): find the pawn's `FirstPersonArms` once, then every 0.25 s walk only its attached children; for the weapon root mesh (`OakWeapon` actor, socket `R_Hand_Weapon`) and its Niagara FX call `SetGbxForeground(false)` and clear `bGbxForeground`, then attach the weapon root to the right controller through `UEVR_UObjectHook` with **zero offset** (every gun shares the rig convention, so no per-weapon tuning). Leave the arms in the foreground pass: un-foregrounding them put the arms mesh on the right eye's position and caused a black flicker. No global object scans (an early version scanned ~22k components every 0.5 s → stutter, and long frames turned Y taps into weapon-wheel holds).

## View rotated left on every shot / camera shake
The game applies a per-shot yaw kick to the control rotation; under UEVR its recovery never applies (UEVR keeps game-added yaw by design). Camera position also shakes 0.5–2.5 cm per shot, and haptics jitter the controller tracking by up to ±5°.

Fix (`BL4_RecoilFix.lua`, in `on_pre_calculate_stereo_view_offset`): predict the expected control yaw from UEVR's own rotation offset, cancel any extra yaw while firing (stick deadzone respected, max 20°/frame), pin camera yaw/roll to the control rotation, freeze camera position while firing (follows body movement only). Disabling the camera modifiers (`CameraModifier_GbxCameraShake` etc.) did not help and brought the flicker back.

## ECHO menu: hangs and the eye split
With Synchronized Sequential the ECHO menu deadlocked the game thread (`[OpenXR] focused stale frame loop`, `synchronize_frame stuck`) and customization never loaded. Native Stereo + 2D Screen mode never hangs, but every rendering method keeps one double-wide stereo buffer (`hmd_width*2`), the 2D screen copies the left half to the left eye and the right half to the right eye, and the ECHO menu draws itself **once across the whole buffer** — so each eye got a different half.

What failed: Extreme Compatibility Mode at runtime (textures not rebuilt → `Failed to close command list`; sequenced through Native it rebuilt but froze the renderer on leaving); un-foregrounding menu props (nothing in the menu is in the foreground pass); forcing one view into a single-width target (crashed on menu open).

What works (`VR_2DScreenFullSource` in our UEVR branch): in 2D Screen mode copy the **entire** double-wide render into each eye's screen (aspect-fit), and size each eye at **half the window width** so the combined buffer has the window's aspect and the menu lays out normally. Menu script: on menu open set Native Stereo + 2D Screen + FullSource; on close restore. UEVR saves live option values at exit, so the script also forces the gameplay values on every launch (quitting from the pause menu used to save head-aim / roomscale-off / 2D-screen state).

## Native Stereo
Works for gameplay once **Depth of Field is disabled** in the game (its bokeh sprites render magenta in the second eye). Remaining defect: loot rarity glows get the wrong color in one eye. UEVR's Native Stereo Fix does not apply (`[NativeStereoFix] Candidate eye pair rejected: family view is missing same-frame construction`), and Ghosting Fix was untested when this was written. Synchronized Sequential is the shipped default.

## Co-op
Gearbox replicates aim via 16-bit `RemoteControlPitch`/`RemoteControlYaw` on the pawn; the host log showed the server tracking the client's pitch correctly with no fix. The "client cannot aim up/down" report traced to the **host** running an old, stuttering script version. Everything else is client-side.

## Useful UEVR Lua facts (joeyhodge fork)
`UEVR_UObjectHook.get_objects_by_class` walks ~1M objects (expensive — avoid per frame); `get_or_add_motion_controller_state` / `set_hand` / `set_permanent`; `find_property` / `get_offset` / `read_byte` / `write_byte`; `on_pre_calculate_stereo_view_offset` gets mutable rotation/position (x = pitch, y = yaw, z = roll); `vr.get_rotation_offset`; `vr.set_mod_value(name, "true"/"0"/…)` changes any option live; `json.load_file` / `dump_file` read and write in the profile's `data/` folder. All scripts share one Lua state, so `_G` globals work across scripts. UEVR cannot set cvars in BL4. Injecting gamepad buttons from `on_xinput_get_state` works only while the VR controllers are awake.
