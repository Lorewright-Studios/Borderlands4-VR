-- BL4_GunFix.lua  v6 — Borderlands 4 + UEVR (joeyhodge fork)
--   * pulls the equipped weapon + its muzzle FX out of Gearbox's "GbxForeground" render pass so they draw in VR
--   * attaches the equipped weapon root mesh to the right controller (re-attaches on weapon swap)
--   * NO global object scans: finds the first-person arms once, then only walks the few components attached to them
local api = uevr.api

local function log(msg) pcall(function() uevr.params.functions.log_info("[BL4GunFix] " .. tostring(msg)) end) end

-- ---------- config ----------
local cfg = {}
pcall(function() cfg = json.load_file("BL4GunFix.json") or {} end)
local function def(k, v) if cfg[k] == nil then cfg[k] = v end end
def("fix_foreground", true)
def("attach_weapon", true)
def("attach_hand", 1)              -- 0 = left, 1 = right
def("check_interval", 0.25)        -- seconds between (cheap) checks of the arms' children
def("arms_search_interval", 3.0)   -- how often to run the (expensive) global search while the arms are unknown
def("verbose", false)
def("weapon_loc_x", 0.0); def("weapon_loc_y", 0.0); def("weapon_loc_z", 0.0)
def("weapon_rot_pitch", 0.0); def("weapon_rot_yaw", 0.0); def("weapon_rot_roll", 0.0)
pcall(function() json.dump_file("BL4GunFix.json", cfg, 2) end)
log(string.format("v6 loaded. fix_foreground=%s attach_weapon=%s hand=%d", tostring(cfg.fix_foreground), tostring(cfg.attach_weapon), cfg.attach_hand))

-- ---------- reflection ----------
local prim_class = api:find_uobject("Class /Script/Engine.PrimitiveComponent")
local skel_class = api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
local fg_setter  = prim_class ~= nil and prim_class:find_function("SetGbxForeground") ~= nil

-- ---------- helpers ----------
local function safe_name(o) if o == nil then return "nil" end local ok, s = pcall(function() return o:get_full_name() end) return ok and s or "?" end
local function class_name(o) if o == nil then return "nil" end local ok, s = pcall(function() return o:get_class():get_fname():to_string() end) return ok and s or "?" end
local function owner_of(comp)
    local ok, o = pcall(function() return comp:GetOwner() end)
    if ok and o ~= nil then return o end
    local ok2, o2 = pcall(function() return comp:get_outer() end)
    return ok2 and o2 or nil
end
local function is_foreground(comp) local ok, v = pcall(function() return comp.bGbxForeground end) return ok and v == true end
local function alive(o) local ok, v = pcall(function() return UEVR_UObjectHook.exists(o) end) return ok and v == true end
local function children_of(comp)
    local list = nil
    pcall(function() list = comp.AttachChildren end)
    return list
end
local function refresh_render_state(comp)
    local ok, v = pcall(function() return comp.bRenderCustomDepth end)
    pcall(function() comp:SetRenderCustomDepth(not v); comp:SetRenderCustomDepth(v and true or false) end)
end
local function unforeground(comp, info)
    if not cfg.fix_foreground then return end
    if not is_foreground(comp) then return end
    pcall(function()
        if fg_setter then comp:SetGbxForeground(false) end
        comp.bGbxForeground = false
        refresh_render_state(comp)
    end)
    if info and not info.fg_logged then info.fg_logged = true; log("bGbxForeground -> false on " .. safe_name(comp)) end
end
local function rot_offset_quat()
    local p, y, r = math.rad(cfg.weapon_rot_pitch)*0.5, math.rad(cfg.weapon_rot_yaw)*0.5, math.rad(cfg.weapon_rot_roll)*0.5
    local SP, CP, SY, CY, SR, CR = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    local q = UEVR_Quaternionf.new()
    q.x =  CR*SP*SY - SR*CP*CY; q.y = -CR*SP*CY - SR*CP*SY; q.z =  CR*CP*SY - SR*SP*CY; q.w =  CR*CP*CY + SR*SP*SY
    return q
end

-- ---------- state ----------
local arms, arms_pawn_addr = nil, nil
local attached = {}     -- addr -> comp
local info = {}         -- addr -> { fg_logged }
local t_check, t_search = 0, 0

local function get_pawn()
    local ok, p = pcall(function() return api:get_local_pawn(0) end)
    if ok and p then return p end
    local pc = api:get_player_controller(0)
    if pc then return pc.AcknowledgedPawn end
    return nil
end

-- expensive: only used until the arms are found (and again after a pawn change)
local function find_arms(pawn)
    local found = nil
    -- cheap path first: a property on the pawn
    pcall(function() local a = pawn.FirstPersonArms; if a and a:is_a(skel_class) then found = a end end)
    if found then return found end
    -- fallback: one global search for a skeletal mesh owned by the pawn that is in the foreground pass
    local objs = nil
    pcall(function() objs = UEVR_UObjectHook.get_objects_by_class(skel_class, false) end)
    if objs then
        for _, comp in ipairs(objs) do
            local ok = pcall(function()
                if owner_of(comp) == pawn and is_foreground(comp) then
                    local n = comp:get_fname():to_string()
                    if string.find(n, "Arms") or string.find(n, "FirstPerson") then found = comp end
                end
            end)
            if found then break end
        end
    end
    return found
end

local function attach(comp)
    local addr = comp:get_address()
    if attached[addr] then return end
    local ok, err = pcall(function()
        local st = UEVR_UObjectHook.get_or_add_motion_controller_state(comp)
        st:set_hand(cfg.attach_hand)
        st:set_permanent(true)
        local loc = UEVR_Vector3f.new(); loc.x = cfg.weapon_loc_x; loc.y = cfg.weapon_loc_y; loc.z = cfg.weapon_loc_z
        st:set_location_offset(loc)
        st:set_rotation_offset(rot_offset_quat())
    end)
    if ok then attached[addr] = comp; log("attached to hand " .. cfg.attach_hand .. ": " .. safe_name(comp))
    else log("attach failed: " .. tostring(err)) end
end
local function detach(addr, why)
    local comp = attached[addr]
    if not comp then return end
    pcall(function() UEVR_UObjectHook.remove_motion_controller_state(comp) end)
    attached[addr] = nil
    if cfg.verbose then log("detached (" .. why .. ")") end
end

local function check(pawn)
    local kids = children_of(arms)
    if kids == nil then return false end
    local held = {}   -- addr -> true for weapon roots currently held
    local n = 0; pcall(function() n = #kids end)
    for i = 1, n do
        local c = kids[i]
        if c ~= nil then
            local addr = c:get_address()
            info[addr] = info[addr] or {}
            unforeground(c, info[addr])
            -- grandchildren (muzzle flash / shell FX attached to the weapon mesh)
            local gk = children_of(c)
            if gk then
                local m = 0; pcall(function() m = #gk end)
                for j = 1, m do
                    local g = gk[j]
                    if g ~= nil then local ga = g:get_address(); info[ga] = info[ga] or {}; unforeground(g, info[ga]) end
                end
            end
            -- weapon root = skeletal mesh owned by another actor (OakWeapon etc.), visible
            local own = owner_of(c)
            if cfg.attach_weapon and own ~= pawn and c:is_a(skel_class) then
                local vis = true; pcall(function() vis = c.bVisible and not c.bHiddenInGame end)
                local ocn = class_name(own)
                if vis and string.find(ocn, "Weapon") then held[addr] = true; attach(c) end
            end
        end
    end
    for addr, _ in pairs(attached) do
        if not held[addr] then detach(addr, "holstered/hidden") end
    end
    return true
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if _G.BL4_IN_MENU then return end   -- menu-detection script sets this; do nothing while the ECHO menu is open
    t_check = t_check + delta; t_search = t_search + delta
    if t_check < cfg.check_interval then return end
    t_check = 0
    local pawn = get_pawn()
    if not pawn then return end
    local paddr = pawn:get_address()
    if arms ~= nil and (paddr ~= arms_pawn_addr or not alive(arms)) then
        arms = nil
        for addr, _ in pairs(attached) do detach(addr, "pawn changed") end
    end
    if arms == nil then
        if t_search < cfg.arms_search_interval and arms_pawn_addr ~= nil then return end
        t_search = 0
        local a = find_arms(pawn)
        arms_pawn_addr = paddr
        if a then arms = a; log("first-person arms found: " .. safe_name(a)) else return end
    end
    local ok, res = pcall(check, pawn)
    if not ok then log("check error: " .. tostring(res)); arms = nil end
end)

uevr.sdk.callbacks.on_script_reset(function()
    for addr, comp in pairs(attached) do pcall(function() UEVR_UObjectHook.remove_motion_controller_state(comp) end) end
    attached = {}
end)
