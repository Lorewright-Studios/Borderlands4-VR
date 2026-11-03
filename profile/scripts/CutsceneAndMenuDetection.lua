local interval = 0.2
local timeLeft = interval
local shouldRotateInMenu = true
local forcePitchToZero = true
local aimMethod = 2
local switchRenderingMethod = false
-- BL4 ECHO menu handling. menuMode:
--   "extreme"  = Extreme Compatibility Mode + AFR while the menu is open: the game renders ONE mono image and UEVR
--                shows that whole image to both eyes (fixes the left-half/right-half eye split of the map, skill tree,
--                customization previews). Single render per tick, so no Synced Sequential frame-pair deadlock either.
--   "native2d" = Native Stereo + 2D screen (previous attempt: no hang, but each eye got a different half of the menu).
--   "extreme2" = same goal as "extreme", but SEQUENCED: UEVR only rebuilds its eye textures when the AFR state flips
--                (Synced/AFR/Extreme all count as "AFR"), so we step through Native Stereo first (AFR off -> rebuild),
--                then switch Extreme+AFR on (AFR on -> rebuild again with the mono/window backbuffer). Leaving reverses it.
-- menuMode is read from data/BL4_menu_mode.json ({"mode": "..."}) every second so it can be changed mid-game;
-- the new mode applies at the NEXT menu open. Modes: "extreme2" | "native2d" | "native" (Native Stereo, no 2D screen)
-- | "native2dfull" (Native Stereo + 2D screen + whole image in both eyes; Lorewright UEVR build only)
-- | "ss2d" (keep Synced Sequential, 2D screen on) | "none" (do nothing: plain Synced Sequential in the menu).
local menuMode = "native2dfull"
local menuModeFile = "BL4_menu_mode.json"
local menuModePollLeft = 0
local function pollMenuMode(delta)
	menuModePollLeft = menuModePollLeft - delta
	if menuModePollLeft > 0 then return end
	menuModePollLeft = 1.0
	local ok, cfg = pcall(function() return json.load_file(menuModeFile) end)
	if ok and type(cfg) == "table" and type(cfg.mode) == "string" and cfg.mode ~= menuMode then
		menuMode = cfg.mode
		pcall(function() uevr.params.functions.log_info("[CutsceneAndMenuDetection] menu mode -> " .. menuMode .. " (applies at next menu open)") end)
	end
end
local use2DScreenInMenu = false        -- derived per menu open from menuMode (see handleCutscene)
local menuRenderingMethod = nil         -- derived per menu open from menuMode
local sequenceStepDelay = 0.6   -- seconds between sequence steps (UEVR rebuilds on the frame after a change)
local seq = {}                  -- pending steps: { t = seconds left, fn = function }
local extremeLive = false       -- true while Extreme Compatibility is (or is being) switched on
local activeMenuMode = "none"    -- mode in effect for the currently open menu
_G.BL4_IN_MENU = false
-- Startup safety: UEVR saves whatever mod values are live when the game exits. Quitting from the pause menu saves the
-- in-menu values (head aim, roomscale off, 2D screen / extreme mode on), which would make the next launch start broken.
-- Force the gameplay values every launch.
-- Gameplay rendering method: "0" = Native Stereo (half the GPU cost; needs Depth of Field OFF in the game's
-- Visuals options, otherwise the right eye fills with magenta bokeh), "1" = Synchronized Sequential (safe fallback).
local gameplayRenderingMethod = "1"
local function bl4_startup_safety()
	local v = uevr.params.vr
	local function sv(name, value) pcall(function() v.set_mod_value(name, value) end) end
	sv("VR_ExtremeCompatibilityMode", "false")
	sv("VR_2DScreenMode", "false")
	sv("VR_2DScreenFullSource", "false")
	sv("VR_RenderingMethod", gameplayRenderingMethod)
	sv("VR_AimMethod", "2")              -- right controller
	sv("VR_DecoupledPitch", "true")
	sv("VR_RoomscaleMovement", "true")
	sv("VR_RoomscaleMovementSweep", "true")
	pcall(function() v.set_aim_method(2) end)
	pcall(function() v.set_decoupled_pitch_enabled(true) end)
end
bl4_startup_safety()
local renderingMethodGame = "0" -- Native Stereo
local renderingMethodMenu = "1" -- Synced Sequential
local oldIsInCutscene = false
local oldIsInMenu = false
local pitchSetCounter = 0
local lastPitch = nil
local isRotationOffsetSet = false
local rotationOffset = UEVR_Vector3f.new()
local settings = json.load_file('CutsceneAndMenuDetection.json') or {}
settings.menu = settings.menu or {}

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	seqTick(delta)
	pollMenuMode(delta)
	timeLeft = timeLeft - delta

	if timeLeft > 0 then
		return
	end

	timeLeft = interval
	local playerController = uevr.api:get_player_controller(0)

	if not playerController then
		return
	end

	if not playerController.AcknowledgedPawn then
		handleCutscene(true)
		return
	end

	local isInMenu = false
	local isInCutscene = isCutsceneCamera(playerController)

	if not isInCutscene then
		isInMenu = isMenuOpened(playerController)
	end

	handleCutscene(isInCutscene, isInMenu, playerController)
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if state.Gamepad.wButtons & XINPUT_GAMEPAD_START ~= 0 and
		state.Gamepad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER ~= 0 and
		state.Gamepad.wButtons & XINPUT_GAMEPAD_RIGHT_SHOULDER ~= 0 then
		uevr.params.vr.get_rotation_offset(rotationOffset)
		isRotationOffsetSet = true
    end
end)

function isCutsceneCamera(playerController)
	if playerController.PlayerCameraManager and
	    playerController.PlayerCameraManager.ViewTarget and
	    playerController.PlayerCameraManager.ViewTarget.Target then
			local className = tostring(playerController.PlayerCameraManager.ViewTarget.Target:get_class():get_fname())

			if string.find(className, 'CameraActor') or string.find(className, 'CineCam') then
				return true
			end
   end

	if settings.cutscene and settings.cutscene.playerController then
		return isAnyPropertyTrue(playerController, settings.cutscene.playerController)
	end

   return false
end

function isAnyPropertyTrue(object, dictionary)
	if not object then
		return false
	end

	for key,value in pairs(dictionary) do
		if key == 'properties' then
			if isAnyPropertyTrue(object, value) then
				return true
			end
		elseif type(value) == 'table' then
			if isAnyPropertyTrue(object[key], value) then
				return true
			end
		elseif object[value] then
			return true
		end
	end

	return false
end

function isMenuOpened(playerController)
	if settings.menu.playerController then
		return isAnyPropertyTrue(playerController, settings.menu.playerController)
	end

	return playerController.bShowMouseCursor
end

function handleCutscene(isInCutscene, isInMenu, playerController)
	if oldIsInCutscene == isInCutscene and oldIsInMenu == isInMenu  then
		if isInMenu and forcePitchToZero and pitchSetCounter < 2 then
			setPitch(playerController)
		end

		return
	end

	oldIsInMenu = isInMenu
	oldIsInCutscene = isInCutscene
	logState("state change: cutscene=" .. tostring(isInCutscene) .. " menu=" .. tostring(isInMenu))

	if isInCutscene or isInMenu then
		if not isInMenu then
			UEVR_UObjectHook.set_disabled(true)
			uevr.params.vr.set_decoupled_pitch_enabled(false)
		end

		uevr.params.vr.set_aim_method(0)

		if isInMenu then
			setRoomscale(false)
			setRenderingMethod(true)
			_G.BL4_IN_MENU = true
			activeMenuMode = menuMode
			logState("menu open with mode=" .. activeMenuMode)
			if activeMenuMode == "extreme2" then
				enterExtremeMenu()
			elseif activeMenuMode == "native2d" then
				setModValue("VR_RenderingMethod", "0"); setModValue("VR_2DScreenMode", "true")
			elseif activeMenuMode == "native2dfull" then   -- needs the Lorewright UEVR build (VR_2DScreenFullSource)
				setModValue("VR_RenderingMethod", "0"); setModValue("VR_2DScreenFullSource", "true"); setModValue("VR_2DScreenMode", "true")
			elseif activeMenuMode == "native" then
				setModValue("VR_RenderingMethod", "0"); setModValue("VR_2DScreenMode", "false")
			elseif activeMenuMode == "ss2d" then
				setModValue("VR_2DScreenMode", "true")
			end -- "none": leave everything as is
		end

		if not isInMenu or shouldRotateInMenu then
			if isRotationOffsetSet then
				uevr.params.vr.set_rotation_offset(rotationOffset)
			else
				uevr.params.vr.recenter_view()
			end
		end

		if isInMenu and forcePitchToZero then
			lastPitch = nil
			pitchSetCounter = 0
			setPitch(playerController)
		end
	else
		UEVR_UObjectHook.set_disabled(false)
		uevr.params.vr.set_aim_method(aimMethod)
		setRoomscale(true)
		setRenderingMethod(false)
		uevr.params.vr.set_decoupled_pitch_enabled(true)
		_G.BL4_IN_MENU = false
		if activeMenuMode == "extreme2" then
			if extremeLive then leaveExtremeMenu() end
		elseif activeMenuMode ~= "none" then
			logState("menu closed: 2D screen off, rendering method -> " .. gameplayRenderingMethod)
			setModValue("VR_2DScreenMode", "false")
			if activeMenuMode == "native2dfull" then setModValue("VR_2DScreenFullSource", "false") end
			setModValue("VR_RenderingMethod", gameplayRenderingMethod)
		end
		activeMenuMode = "none"
	end
end

function logState(message)
	local ok = pcall(function()
		uevr.params.functions.log_info("[CutsceneAndMenuDetection] " .. message)
	end)

	if not ok then
		print("[CutsceneAndMenuDetection] " .. message)
	end
end

function setModValue(name, value)
	local ok, err = pcall(function()
		uevr.params.vr.set_mod_value(name, value)
	end)

	if not ok then
		logState("set_mod_value failed for " .. name .. ": " .. tostring(err))
	end
end

function seqClear() seq = {} end
function seqAdd(delay, fn) seq[#seq+1] = { t = delay, fn = fn } end
function seqTick(delta)
	if #seq == 0 then return end
	local step = seq[1]
	step.t = step.t - delta
	if step.t <= 0 then
		table.remove(seq, 1)
		local ok, err = pcall(step.fn)
		if not ok then logState("sequence step failed: " .. tostring(err)) end
	end
end
function enterExtremeMenu()
	seqClear()
	extremeLive = true
	logState("menu mono sequence: step 1 -> Native Stereo (AFR off, textures rebuild)")
	setModValue("VR_2DScreenMode", "false")
	setModValue("VR_ExtremeCompatibilityMode", "false")
	setModValue("VR_RenderingMethod", "0")
	seqAdd(sequenceStepDelay, function()
		logState("menu mono sequence: step 2 -> AFR + Extreme Compatibility (mono, rebuild with window backbuffer)")
		setModValue("VR_RenderingMethod", "2")
		setModValue("VR_ExtremeCompatibilityMode", "true")
	end)
end
function leaveExtremeMenu()
	seqClear()
	logState("menu mono sequence: leave step 1 -> Extreme off + Native Stereo (AFR off, rebuild)")
	setModValue("VR_ExtremeCompatibilityMode", "false")
	setModValue("VR_RenderingMethod", "0")
	seqAdd(sequenceStepDelay, function()
		logState("menu mono sequence: leave step 2 -> Synchronized Sequential")
		setModValue("VR_RenderingMethod", gameplayRenderingMethod)
		extremeLive = false
	end)
end

function setRoomscale(enabled)
	local value = enabled and "true" or "false"
	logState("roomscale + sweep -> " .. value)
	setModValue("VR_RoomscaleMovement", value)
	setModValue("VR_RoomscaleMovementSweep", value)
end

function setRenderingMethod(inMenu)
	if not switchRenderingMethod then
		return
	end

	local value = inMenu and renderingMethodMenu or renderingMethodGame
	logState("rendering method -> " .. value)
	setModValue("VR_RenderingMethod", value)
end

function setPitch(playerController)
	if playerController.PlayerCameraManager and
		playerController.PlayerCameraManager.ViewTarget then
		local pov = playerController.PlayerCameraManager.ViewTarget.POV

		if pov and (pov.Rotation.Pitch < -5 or pov.Rotation.Pitch > 5) then
			if lastPitch ~= nil and math.abs(lastPitch - pov.Rotation.Pitch) < 1 then
				pitchSetCounter = pitchSetCounter + 1
				local rotation = playerController:GetControlRotation()
				rotation.Pitch = 0

				playerController:SetControlRotation(rotation)
			else
				lastPitch = pov.Rotation.Pitch
			end
		end
	end
end