-- BL4_RecoilFix.lua v5 — firing must not move the camera (joeyhodge UEVR fork, Borderlands 4)
--  1) cancels the per-shot yaw kick the game adds to the control rotation. The expected yaw is predicted from
--     UEVR's OWN rotation offset (the exact controller sample UEVR used), so controller tracking jitter during
--     haptics never leaks into the view.
--  2) pins the camera yaw/roll UEVR sees to the (corrected) control rotation.
--  3) while firing, freezes the camera position (follows body movement only).
local api = uevr.api
local vr  = uevr.params.vr
local function log(msg) pcall(function() uevr.params.functions.log_info("[BL4RecoilFix] " .. tostring(msg)) end) end

local cfg = {}
pcall(function() cfg = json.load_file("BL4RecoilFix.json") or {} end)
local function def(k, v) if cfg[k] == nil then cfg[k] = v end end
def("enabled", true)
def("only_when_firing", true)
def("trigger_threshold", 30)
def("fire_latch_seconds", 0.5)
def("stick_deadzone", 0.25)
def("max_cancel_deg", 20.0)
def("stabilize_view_yaw", true)
def("stabilize_view_roll", true)
def("freeze_position_while_firing", true)
def("log_stats_seconds", 0)
pcall(function() json.dump_file("BL4RecoilFix.json", cfg, 2) end)
log(string.format("v5 loaded. freeze_pos=%s stabilize_view=%s only_when_firing=%s", tostring(cfg.freeze_position_while_firing), tostring(cfg.stabilize_view_yaw), tostring(cfg.only_when_firing)))

local function wrap180(a) return (a + 180) % 360 - 180 end
local function controller_aim_active()
    local ok, m = pcall(function() return vr.get_aim_method() end)
    return ok and m ~= nil and m >= 2
end
local function q_yaw(q)
    local x, y, z, w = q.x, q.y, q.z, q.w
    local fx = -(2*(x*z + w*y)); local fz = -(1 - 2*(x*x + y*y))
    return math.deg(math.atan(fx, -fz))
end
local oq = UEVR_Quaternionf.new()
local function rot_offset_yaw()
    local ok = pcall(function() vr.get_rotation_offset(oq) end)
    if not ok then return nil end
    return q_yaw(oq)
end

local t, frame, last_frame_done = 0, 0, -1
local trigger, stick_x, last_fire = 0, 0, -100
local last_ctrl_yaw, last_off_yaw = nil, nil
local cancels, total_cancelled, stat_t = 0, 0, 0
local freeze = nil

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if state == nil then return end
    trigger = state.Gamepad.bRightTrigger or 0
    stick_x = (state.Gamepad.sThumbRX or 0) / 32767.0
end)

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    t = t + delta; frame = frame + 1
    if trigger > cfg.trigger_threshold then last_fire = t end
    if cfg.log_stats_seconds > 0 then
        stat_t = stat_t + delta
        if stat_t >= cfg.log_stats_seconds then
            stat_t = 0
            if cancels > 0 then log(string.format("cancelled %d yaw kicks totalling %.1f deg in the last %.0fs", cancels, total_cancelled, cfg.log_stats_seconds)) end
            cancels, total_cancelled = 0, 0
        end
    end
end)

local function pawn_location(pc)
    local p = nil
    pcall(function() p = pc.AcknowledgedPawn:K2_GetActorLocation() end)
    if p then return { x = p.x or p.X, y = p.y or p.Y, z = p.z or p.Z } end
    return nil
end

uevr.sdk.callbacks.on_pre_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not cfg.enabled then return end
    local pc = api:get_player_controller(0)
    if not pc then return end
    local ok, cr = pcall(function() return pc:GetControlRotation() end)
    if not ok or not cr then return end
    local active = controller_aim_active()
    local firing = (t - last_fire) <= cfg.fire_latch_seconds

    -- (1) cancel per-shot yaw kick, once per frame, predicting from UEVR's own rotation offset
    if active and last_frame_done ~= frame then
        last_frame_done = frame
        local off = rot_offset_yaw()
        local cur = cr.Yaw
        if off ~= nil and last_ctrl_yaw ~= nil and last_off_yaw ~= nil then
            local expected = last_ctrl_yaw - wrap180(off - last_off_yaw)   -- controller turned right => offset yaw went down
            local kick = wrap180(cur - expected)
            local allow = (not cfg.only_when_firing) or firing
            if allow and math.abs(stick_x) < cfg.stick_deadzone and math.abs(kick) > 0.01 and math.abs(kick) < cfg.max_cancel_deg then
                cr.Yaw = wrap180(cur - kick)
                pcall(function() pc:SetControlRotation(cr) end)
                cur = cr.Yaw
                cancels = cancels + 1; total_cancelled = total_cancelled + math.abs(kick)
            end
        end
        last_ctrl_yaw, last_off_yaw = cur, off
    elseif not active then
        last_ctrl_yaw, last_off_yaw = nil, nil
    end

    -- (2) pin camera yaw/roll to the control rotation
    if active and rotation ~= nil and cfg.stabilize_view_yaw then
        if math.abs(wrap180(rotation.y - cr.Yaw)) < 45 then
            rotation.y = cr.Yaw
            if cfg.stabilize_view_roll then rotation.z = 0.0 end
        end
    end

    -- (3) freeze camera position while firing (follow body movement only)
    if active and position ~= nil and cfg.freeze_position_while_firing then
        if firing then
            local pl = pawn_location(pc)
            if freeze == nil then
                if pl then freeze = { cam = { x = position.x, y = position.y, z = position.z }, pawn = pl } end
            elseif pl then
                local nx = freeze.cam.x + (pl.x - freeze.pawn.x)
                local ny = freeze.cam.y + (pl.y - freeze.pawn.y)
                local nz = freeze.cam.z + (pl.z - freeze.pawn.z)
                local d = math.sqrt((position.x - nx)^2 + (position.y - ny)^2 + (position.z - nz)^2)
                if d < 60.0 then position.x = nx; position.y = ny; position.z = nz
                else freeze = { cam = { x = position.x, y = position.y, z = position.z }, pawn = pl } end
            end
        else
            freeze = nil
        end
    end
end)
