-- Offline simulation of the addon: several fake clients on a fake server, no WoW needed.
-- Each client loads its own copy of the addon against stubbed WoW APIs, and the server routes
-- guild chat, whispers and addon messages between them on a virtual clock, with latency and drops.
--
-- Usage: lua5.1 test/sim.lua [-v] [path/to/FunnyEcho.lua]
--   -v   print each test's chat timeline
-- Exits non-zero if a test fails. KNOWN tests document open issues and don't fail the run.

local verbose = false
local addonPath
for _, a in ipairs(arg) do
    if a == "-v" then
        verbose = true
    else
        addonPath = a
    end
end
addonPath = addonPath or ((arg[0]:match("^(.*)[/\\]") or ".") .. "/../addon/FunnyEcho.lua")

-- Secret values (12.0+): opaque, indexing them errors like in-game.
local secretMT = {
    __index = function() error("attempt to index a secret value", 2) end,
    __tostring = function() return "<secret>" end,
}

local function Secret(value)
    return setmetatable({ value = value }, secretMT)
end

local function IsSecretValue(value)
    return type(value) == "table" and getmetatable(value) == secretMT
end

-- Globals the addon may read as nil; reading any other missing global is reported as a typo.
local ALLOWED_NIL = {
    CHAT_TIMESTAMP_FORMAT = true, -- not in Forever (ChatFrameUtil has it); v2.0.0 still checks for it
}

local STDLIB = {
    "pairs", "ipairs", "select", "type", "tostring", "tonumber", "next", "unpack", "pcall", "xpcall",
    "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset", "table", "string", "math",
}

local NUM_CHAT_WINDOWS = 10

local Sim = {}
Sim.__index = Sim

local Client = {}
Client.__index = Client

function Sim.new()
    local sim = setmetatable({}, Sim)
    -- GetTime() is uptime, never near 0.
    sim.t0 = 1000
    sim.now = sim.t0
    sim.queue = {}
    sim.seq = 0
    sim.lineID = 0
    sim.clients = {}
    sim.chatLog = {}
    sim.errors = {}
    sim.violations = {}
    sim.chatLatency = 0.1
    sim.addonLatency = 0.1
    -- Optional hooks, set by tests:
    -- sim.dropChat(msg) -> true drops the message for everyone (spam filter, muted rank).
    -- sim.chatLatencyFn(msg, receiver) -> seconds, overrides chatLatency.
    return sim
end

function Sim:Time()
    return self.now - self.t0
end

function Sim:Protect(fn, ...)
    local args, n = { ... }, select("#", ...)
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, debug.traceback)
    if not ok then
        table.insert(self.errors, ("t=%.2f %s"):format(self:Time(), err))
    end
end

-- Equal times run in scheduling order.
function Sim:Schedule(time, fn)
    self.seq = self.seq + 1
    local q = self.queue
    local i = #q
    while i > 0 and q[i].time > time do
        i = i - 1
    end
    table.insert(q, i + 1, { time = time, fn = fn })
end

function Sim:At(t, fn)
    self:Schedule(self.t0 + t, fn)
end

function Sim:PressEvery(client, interval, from, to)
    for i = 0, math.floor((to - from) / interval + 1e-9) do
        self:At(from + i * interval, function() client:PressKey() end)
    end
end

function Sim:RunUntil(t)
    local target = self.t0 + t
    while self.queue[1] and self.queue[1].time <= target do
        local item = table.remove(self.queue, 1)
        self.now = item.time
        self:Protect(item.fn)
    end
    self.now = target
end

function Sim:GuildMembers()
    local members = {}
    for _, c in ipairs(self.clients) do
        if c.inGuild then
            table.insert(members, c)
        end
    end
    return members
end

local CHAT_EVENTS = {
    GUILD = "CHAT_MSG_GUILD",
    WHISPER = "CHAT_MSG_WHISPER_INFORM",
    SAY = "CHAT_MSG_SAY",
    PARTY = "CHAT_MSG_PARTY",
}

function Sim:Chat(sender, text, chatType, origin)
    local msg = {
        from = sender, text = text, chatType = chatType, origin = origin, at = self:Time(),
    }
    table.insert(self.chatLog, msg)
    if self.dropChat and self.dropChat(msg) then
        msg.dropped = true
        return
    end
    -- Only guild chat reaches other clients; the rest is said where the guild can't see it.
    local receivers = chatType == "GUILD" and self:GuildMembers() or { sender }
    local event = assert(CHAT_EVENTS[chatType], chatType)
    self.lineID = self.lineID + 1
    local lineID = self.lineID
    for _, r in ipairs(receivers) do
        local latency = self.chatLatencyFn and self.chatLatencyFn(msg, r) or self.chatLatency
        self:Schedule(self.now + latency, function() r:ReceiveChat(event, msg, lineID) end)
    end
end

function Sim:Addon(sender, prefix, text, chatType)
    if chatType ~= "GUILD" then
        table.insert(self.violations, ("%s sent an addon message to %s"):format(sender.name, tostring(chatType)))
        return
    end
    if not sender.inGuild then
        return
    end
    table.insert(self.chatLog, { from = sender, text = text, chatType = "ADDON", at = self:Time() })
    for _, r in ipairs(self:GuildMembers()) do
        self:Schedule(self.now + self.addonLatency, function() r:ReceiveAddon(prefix, text, chatType, sender) end)
    end
end

-- opts.guildFrames: chat windows showing guild chat (default: the main window only).
function Sim:AddClient(name, opts)
    opts = opts or {}
    local c = setmetatable({
        sim = self,
        name = name,
        guid = ("Player-1-%08X"):format(#self.clients + 1),
        inGuild = opts.inGuild ~= false,
        guildFrames = opts.guildFrames or { 1 },
        frames = {},
        chatFrames = {},
        prefixes = {},
        -- Test knobs:
        blocked = false, -- addon chat sends fire ADDON_ACTION_BLOCKED instead of going out
        lockdown = false, -- chat messaging lockdown: InChatMessagingLockdown() is true, sends blocked
        secretChat = false, -- incoming chat arrives as secret values (restricted content)
        timestampFormat = nil, -- the chat timestamps setting; nil is off
        blockedCount = 0,
        hardware = false,
        typing = false,
    }, Client)
    table.insert(self.clients, c)
    c:Load()
    return c
end

function Client:Load()
    local c = self
    local env = {}
    for _, k in ipairs(STDLIB) do
        env[k] = _G[k]
    end
    env._G = env
    env.time = os.time
    -- Forever's timestamp helpers; it has no BetterDate or CHAT_TIMESTAMP_FORMAT globals.
    env.ChatFrameUtil = { GetTimestampFormat = function() return c.timestampFormat end }
    env.TimeUtil = { BetterDate = function(fmt, t) return os.date(fmt, t) end }
    env.GetTime = function() return c.sim.now end
    env.issecretvalue = IsSecretValue
    env.tContains = function(t, value)
        for _, v in ipairs(t) do
            if v == value then
                return true
            end
        end
        return false
    end
    env.NUM_CHAT_WINDOWS = NUM_CHAT_WINDOWS
    env.CHAT_GUILD_GET = "|Hchannel:GUILD|h[Guild]|h %s: "
    env.ChatTypeInfo = { GUILD = { r = 0.25, g = 1, b = 0.25, id = 4 } }
    env.UnitGUID = function(unit)
        if unit == "player" then
            return c.guid
        end
    end
    env.IsInGuild = function() return c.inGuild end
    env.CreateFrame = function() return c:NewFrame() end
    env.C_Timer = {
        After = function(delay, fn) c.sim:Schedule(c.sim.now + delay, fn) end,
    }
    env.C_ChatInfo = {
        SendChatMessage = function(text, chatType) c:SendChat(text, chatType) end,
        SendAddonMessage = function(prefix, text, chatType) c.sim:Addon(c, prefix, text, chatType) end,
        RegisterAddonMessagePrefix = function(prefix)
            c.prefixes[prefix] = true
            return true
        end,
        InChatMessagingLockdown = function() return c.lockdown end,
    }
    for i = 1, NUM_CHAT_WINDOWS do
        local chatFrame = { messageTypeList = {}, lines = {} }
        function chatFrame:AddMessage(text)
            table.insert(self.lines, { text = text, at = c.sim:Time() })
        end
        env["ChatFrame" .. i] = chatFrame
        c.chatFrames[i] = chatFrame
    end
    for _, i in ipairs(c.guildFrames) do
        table.insert(c.chatFrames[i].messageTypeList, "GUILD")
    end
    env.DEFAULT_CHAT_FRAME = env.ChatFrame1
    setmetatable(env, {
        __index = function(_, k)
            if not ALLOWED_NIL[k] then
                table.insert(c.sim.violations, ("%s read undefined global %s"):format(c.name, tostring(k)))
            end
        end,
    })

    local chunk = assert(loadfile(addonPath))
    setfenv(chunk, env)
    self.sim:Protect(chunk)
    self:FireEvent("PLAYER_LOGIN")
end

function Client:NewFrame()
    local f = { shown = true, keyboard = false, events = {}, scripts = {} }
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    function f:EnableKeyboard(enable) self.keyboard = enable end
    function f:SetPropagateKeyboardInput(propagate) self.propagate = propagate end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:RegisterEvent(event) self.events[event] = true end
    table.insert(self.frames, f)
    return f
end

function Client:FireEvent(event, ...)
    for _, f in ipairs(self.frames) do
        if f.events[event] and f.scripts.OnEvent then
            self.sim:Protect(f.scripts.OnEvent, f, event, ...)
        end
    end
end

-- A hardware event: shown keyboard-enabled frames see it.
function Client:PressKey(key)
    self.hardware = true
    for _, f in ipairs(self.frames) do
        if f.shown and f.keyboard and f.scripts.OnKeyDown then
            self.sim:Protect(f.scripts.OnKeyDown, f, key or "W")
        end
    end
    self.hardware = false
end

-- The player sends a line from the chat box. The Enter that opens the box is a keypress; after that
-- the box has keyboard focus, so typing and sending reach no other frame.
function Client:Type(chatType, text)
    self:PressKey("ENTER")
    self.hardware, self.typing = true, true
    self:SendChat(text, chatType)
    self.hardware, self.typing = false, false
end

function Client:SendChat(text, chatType)
    local origin = self.typing and "typed" or "addon"
    if not self.hardware then
        table.insert(self.sim.violations, ("%s sent %q to %s outside a keypress"):format(self.name, text, chatType))
    end
    if (self.blocked or self.lockdown) and origin == "addon" then
        self.blockedCount = self.blockedCount + 1
        self:FireEvent("ADDON_ACTION_BLOCKED", "HEH", "SendChatMessage")
        return
    end
    self.sim:Chat(self, text, chatType, origin)
end

function Client:ReceiveChat(event, msg, lineID)
    local text, guid = msg.text, msg.from.guid
    if self.secretChat then
        text, guid = Secret(text), Secret(guid)
    end
    -- text, playerName, languageName, channelName, playerName2, specialFlags, zoneChannelID,
    -- channelIndex, channelBaseName, languageID, lineID, guid
    self:FireEvent(event, text, msg.from.name, "Common", "", msg.from.name, "", 0, 0, "", 7, lineID, guid)
end

function Client:ReceiveAddon(prefix, text, channel, sender)
    -- Only registered prefixes are delivered.
    if not self.prefixes[prefix] then
        return
    end
    self:FireEvent("CHAT_MSG_ADDON", prefix, text, channel, sender.name .. "-Realm", self.name, 0, 0, "", 0)
end

-- Guild echoes the addon sent for us in [from, to).
function Client:Echoes(from, to)
    local n = 0
    for _, m in ipairs(self.sim.chatLog) do
        if m.from == self and m.origin == "addon" and m.chatType == "GUILD"
            and m.at >= (from or -math.huge) and m.at < (to or math.huge) then
            n = n + 1
        end
    end
    return n
end

-- Cats shown in chat window i, or in all windows.
function Client:Cats(i)
    local n = 0
    for index, chatFrame in ipairs(self.chatFrames) do
        if not i or i == index then
            for _, line in ipairs(chatFrame.lines) do
                if line.text:find("heh-cat", 1, true) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function Sim:PrintTimeline()
    local entries = {}
    for _, m in ipairs(self.chatLog) do
        local what
        if m.chatType == "ADDON" then
            what = "trigger"
        else
            what = ("%-7s %q (%s)%s"):format(m.chatType, m.text, m.origin, m.dropped and " DROPPED" or "")
        end
        table.insert(entries, { at = m.at, text = ("%-6s %s"):format(m.from.name, what) })
    end
    for _, c in ipairs(self.clients) do
        for i, chatFrame in ipairs(c.chatFrames) do
            for _, line in ipairs(chatFrame.lines) do
                table.insert(entries, { at = line.at, text = ("%-6s cat in ChatFrame%d"):format(c.name, i) })
            end
        end
    end
    table.sort(entries, function(a, b) return a.at < b.at end)
    for _, e in ipairs(entries) do
        print(("        %8.2fs  %s"):format(e.at, e.text))
    end
end

-- Tests -----------------------------------------------------------------------------------------

local tests = {}

local function Test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

-- Open issues: reported, but they don't fail the run.
local function Known(name, fn)
    table.insert(tests, { name = name, fn = fn, known = true })
end

Test("guild HEH: everyone echoes and gets one cat", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(b, 0.5, 1, 6)
    sim:PressEvery(c, 0.5, 1, 6)
    sim:RunUntil(30)
    check(b:Echoes() >= 1, "Bob echoed")
    check(c:Echoes() >= 1, "Cleo echoed")
    for _, p in ipairs({ a, b, c }) do
        check(p:Cats() == 1, ("%s got one cat (got %d)"):format(p.name, p:Cats()))
    end
end)

Test("active players echo once a second while the chorus is open (flooding is a feature)", function(sim, check)
    local a, b = sim:AddClient("Alice"), sim:AddClient("Bob")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(b, 0.25, 0.3, 8)
    sim:RunUntil(30)
    local n = b:Echoes()
    check(n >= 4 and n <= 6, ("Bob echoed about once a second for 5s (got %d)"):format(n))
end)

Test("guild HEH with everyone idle: nobody echoes, everyone still gets the cat", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:RunUntil(30)
    for _, p in ipairs({ a, b, c }) do
        check(p:Echoes() == 0, ("%s didn't echo"):format(p.name))
        check(p:Cats() == 1, ("%s got one cat (got %d)"):format(p.name, p:Cats()))
    end
end)

Test("two players HEH at once: one chorus, one cat each", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:At(0, function() b:Type("GUILD", "HEH") end)
    sim:PressEvery(c, 0.5, 1, 6)
    sim:RunUntil(30)
    for _, p in ipairs({ a, b, c }) do
        check(p:Cats() == 1, ("%s got one cat (got %d)"):format(p.name, p:Cats()))
    end
end)

Test("a dropped echo doesn't swallow a later HEH (v2.0.0 bug)", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    local dropped = false
    sim.dropChat = function(msg)
        if msg.from == a and msg.origin == "addon" and not dropped then
            dropped = true
            return true
        end
    end
    sim:At(0, function() b:Type("GUILD", "HEH") end)
    sim:PressEvery(a, 0.5, 0.5, 6)
    sim:At(60, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(b, 0.5, 60.5, 66)
    sim:PressEvery(c, 0.5, 60.5, 66)
    sim:RunUntil(90)
    check(dropped, "the server dropped one of Alice's echoes")
    check(b:Echoes(60, 70) >= 1, "Bob joined the chorus Alice started at 60s")
    check(a:Cats() == 2, ("Alice got a cat for both choruses (got %d)"):format(a:Cats()))
end)

Test("secret chat in restricted content: no errors, HEH works again after", function(sim, check)
    local s, b = sim:AddClient("Sage"), sim:AddClient("Bob")
    s.secretChat = true
    sim:At(0, function() b:Type("GUILD", "HEH") end)
    sim:PressEvery(s, 0.5, 0.5, 6)
    sim:At(30, function() s.secretChat = false end)
    sim:At(60, function() s:Type("GUILD", "HEH") end)
    sim:PressEvery(b, 0.5, 60.5, 66)
    sim:RunUntil(90)
    check(s:Echoes(0, 10) >= 1, "Sage echoed in the restricted chorus")
    -- Bob's HEH was in guild chat: Sage sees it, the addon just can't read it.
    check(s:Cats() == 2, ("Sage got a cat for both choruses (got %d)"):format(s:Cats()))
    check(b:Echoes(60, 70) >= 1, "Bob joined the chorus Sage started after leaving restricted content")
end)

Test("HEH in a whisper with everyone idle: no cat (v2.0.0 bug)", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() b:Type("WHISPER", "HEH") end)
    sim:RunUntil(30)
    for _, p in ipairs({ a, b, c }) do
        check(p:Echoes() == 0, ("%s didn't echo"):format(p.name))
        check(p:Cats() == 0, ("%s got no cat (got %d)"):format(p.name, p:Cats()))
    end
end)

Test("HEH in a whisper with people active: the guild echoes and gets the cat", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() b:Type("WHISPER", "HEH") end)
    sim:PressEvery(a, 0.5, 1, 6)
    sim:PressEvery(c, 0.5, 1, 6)
    sim:RunUntil(30)
    check(a:Echoes() >= 1, "Alice echoed")
    check(c:Echoes() >= 1, "Cleo echoed")
    for _, p in ipairs({ a, b, c }) do
        check(p:Cats() == 1, ("%s got one cat (got %d)"):format(p.name, p:Cats()))
    end
end)

Test("a blocked echo only skips that chorus (v2.0.0 bug)", function(sim, check)
    local a, c = sim:AddClient("Alice"), sim:AddClient("Cleo")
    c.blocked = true
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(c, 0.5, 0.5, 6)
    sim:At(20, function() c.blocked = false end)
    sim:At(30, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(c, 0.5, 30.5, 36)
    sim:RunUntil(60)
    check(c.blockedCount >= 1, "Cleo's echo was blocked in the first chorus")
    check(c:Echoes(0, 20) == 0, "Cleo sent nothing while blocked")
    check(c:Echoes(30, 40) >= 1, "Cleo echoed in the next chorus")
end)

Test("chat lockdown: no send attempts during it, the next keypress after it echoes", function(sim, check)
    local a, c = sim:AddClient("Alice"), sim:AddClient("Cleo")
    c.lockdown = true
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(c, 0.5, 0.5, 2)
    sim:At(2.2, function() c.lockdown = false end)
    sim:PressEvery(c, 0.5, 2.5, 6)
    sim:RunUntil(30)
    check(c.blockedCount == 0, ("Cleo didn't try to send during lockdown (blocked %d times)"):format(c.blockedCount))
    check(c:Echoes(0, 2.2) == 0, "Cleo sent nothing during lockdown")
    check(c:Echoes(2.2, 6) >= 1, "Cleo echoed once lockdown ended")
end)

Test("the cat gets the chat timestamp when timestamps are on", function(sim, check)
    local a = sim:AddClient("Alice")
    a.timestampFormat = "TS| "
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:RunUntil(30)
    local line = a.chatFrames[1].lines[1]
    check(line and line.text:sub(1, 4) == "TS| ",
        ("the cat starts with the timestamp (got %q)"):format(line and line.text or "no cat"))
end)

Test("a missed echo goes out just after the window, not an hour later (v2.0.0 bug)", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:At(7, function() c:PressKey() end)
    sim:At(100, function() a:Type("GUILD", "HEH") end)
    sim:At(3700, function() b:PressKey() end)
    sim:RunUntil(3800)
    check(c:Echoes(0, 10) == 1, ("Cleo's late echo went out 2s after the window (got %d)"):format(c:Echoes(0, 10)))
    check(b:Echoes(100, 4000) == 0, "Bob's keypress an hour later sent nothing")
end)

Test("the cat only shows in windows that show guild chat (v2.0.0 bug)", function(sim, check)
    local d = sim:AddClient("Dana", { guildFrames = {} })
    local e = sim:AddClient("Eli", { guildFrames = { 1 } })
    local f = sim:AddClient("Finn", { guildFrames = { 1, 3 } })
    sim:At(0, function() e:Type("GUILD", "HEH") end)
    sim:RunUntil(30)
    check(d:Cats() == 0, ("Dana shows guild chat nowhere: no cat (got %d)"):format(d:Cats()))
    check(e:Cats(1) == 1 and e:Cats() == 1, "Eli got the cat in the main window")
    check(f:Cats(1) == 1 and f:Cats(3) == 1 and f:Cats() == 2, "Finn got the cat in both guild windows")
end)

Test("an echo lagging 4s doesn't start a second chorus", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim.chatLatencyFn = function(msg)
        if msg.from == a and msg.origin == "addon" then
            return 4
        end
        return 0.1
    end
    sim:At(0, function() b:Type("GUILD", "HEH") end)
    sim:PressEvery(a, 0.5, 0.5, 6)
    sim:PressEvery(c, 0.5, 0.5, 20)
    sim:RunUntil(40)
    check(c:Echoes(5.3, 40) == 0, ("Cleo saw no second chorus (echoed %d times after it)"):format(c:Echoes(5.3, 40)))
end)

Test("a chorus right after another doesn't borrow its cat", function(sim, check)
    local a, b, c = sim:AddClient("Alice"), sim:AddClient("Bob"), sim:AddClient("Cleo")
    sim:At(0, function() a:Type("GUILD", "HEH") end)
    sim:PressEvery(b, 0.5, 0.5, 5)
    -- Bob already echoed, so his Enter sends no late echo; nobody echoes the second chorus.
    sim:At(6, function() b:Type("WHISPER", "HEH") end)
    sim:RunUntil(30)
    for _, p in ipairs({ a, b, c }) do
        check(p:Cats() == 1, ("%s got one cat, none for the silent second chorus (got %d)"):format(p.name, p:Cats()))
    end
end)

-- Runner ----------------------------------------------------------------------------------------

print(("Addon: %s"):format(addonPath))
local failed, known = 0, 0
for _, t in ipairs(tests) do
    local sim = Sim.new()
    local problems = {}
    local function check(ok, what)
        if not ok then
            table.insert(problems, what)
        end
    end
    sim:Protect(t.fn, sim, check)
    for _, err in ipairs(sim.errors) do
        table.insert(problems, "Lua error: " .. err)
    end
    for _, v in ipairs(sim.violations) do
        table.insert(problems, v)
    end
    local status
    if #problems == 0 then
        status = "PASS "
    elseif t.known then
        status = "KNOWN"
        known = known + 1
    else
        status = "FAIL "
        failed = failed + 1
    end
    print(("%s %s"):format(status, t.name))
    for _, p in ipairs(problems) do
        print("        - " .. p)
    end
    if verbose then
        sim:PrintTimeline()
    end
end
print(("%d tests, %d failed, %d known issues"):format(#tests, failed, known))
os.exit(failed == 0 and 0 or 1)
