-- Runs inside wow-ui-sim (WoW Forever build) against the real Forever UI: one player, events fired in
-- by hand, simulated clock. Choirs between several players are covered by test/sim.lua.
-- Run with test/wowsim.sh.

local PREFIX = "HEH_FUNNYECHO"
local ME = UnitGUID("player")
local OTHER = "Player-1-00000002"

A_Admin.SetManualClock(0)

-- HEH's key-catching frame is local to the addon; find it by where its script was defined.
local function FindKeyFrame()
    local f = EnumerateFrames()
    while f do
        local script = f:GetScript("OnKeyDown")
        if script and debug.getinfo(script, "S").source:find("HEH/FunnyEcho.lua", 1, true) then
            return f
        end
        f = EnumerateFrames(f)
    end
end
local keyFrame = FindKeyFrame()

-- wow-ui-sim doesn't deliver outgoing chat; its SendChatMessage writes the raw text to ChatFrame1.
local lines = {}
for i = 1, NUM_CHAT_WINDOWS do
    hooksecurefunc(_G["ChatFrame" .. i], "AddMessage", function(_, text)
        table.insert(lines, { frame = i, text = text })
    end)
end

local triggers = {}
hooksecurefunc(C_ChatInfo, "SendAddonMessage", function(prefix, text, chatType)
    if prefix == PREFIX then
        table.insert(triggers, { text = text, chatType = chatType })
    end
end)

local errors = {}
seterrorhandler(function(err) table.insert(errors, tostring(err)) end)

local function Count(match)
    local n = 0
    for _, line in ipairs(lines) do
        if match(line) then
            n = n + 1
        end
    end
    return n
end

local function Echoes()
    return Count(function(line) return line.frame == 1 and line.text == "HEH" end)
end

local function Cats(frame)
    return Count(function(line)
        return line.text:find("heh-cat", 1, true) and (not frame or line.frame == frame)
    end)
end

-- CHAT_MSG_* payload as documented for Forever, discordInfo (arg 18) included; userID 0 is a message
-- that didn't come from Discord.
local NOT_DISCORD = {
    userID = 0, globalName = "", type = 0, lastOnlineGUID = "", lastOnlineName = "", hasAttachment = false,
    hasPoll = false, hasEmbed = false, hasSticker = false, hasEmoji = false, hasError = false,
}
local lineID = 0
local function Chat(event, text, sender, guid)
    lineID = lineID + 1
    A_Admin.FireEvent(event, text, sender, "Common", "", sender, "", 0, 0, "", 7, lineID, guid, 0,
        false, false, false, false, NOT_DISCORD)
end

local function Trigger(text)
    A_Admin.FireEvent("CHAT_MSG_ADDON", PREFIX, text, "GUILD", "Bob-Realm", "", 0, 0, "", 0)
end

-- Keys only reach shown frames.
local function PressKey()
    if keyFrame:IsShown() then
        keyFrame:GetScript("OnKeyDown")(keyFrame, "W")
    end
end

-- Past any open chorus, late echo or pending echo from the previous test.
local function Fresh()
    A_Admin.AdvanceTime(60)
    wipe(lines)
    wipe(triggers)
    wipe(errors)
    ChatFrame_AddMessageGroup(ChatFrame1, "GUILD")
end

-- Only ours: wow-ui-sim doesn't model every Forever API Blizzard's chat display code calls.
local function NoErrors()
    local ours = {}
    for _, err in ipairs(errors) do
        if err:find("FunnyEcho.lua", 1, true) then
            table.insert(ours, err)
        end
    end
    assertEquals("", table.concat(ours, "\n"))
end

test("loads in Forever and finds its key frame", function()
    assertNotNil(keyFrame)
    assertFalse(keyFrame:IsShown())
    assertTrue(keyFrame:GetPropagateKeyboardInput())
    NoErrors()
end)

test("HEH in guild sends a guild-tagged trigger", function()
    Fresh()
    Chat("CHAT_MSG_GUILD", "HEH", "Me", ME)
    assertCount(1, triggers)
    assertEquals(ME .. ":GUILD", triggers[1].text)
    assertEquals("GUILD", triggers[1].chatType)
    NoErrors()
end)

test("HEH in a whisper sends an untagged trigger", function()
    Fresh()
    Chat("CHAT_MSG_WHISPER_INFORM", "HEH", "Friend", "Player-1-00000099")
    assertCount(1, triggers)
    assertEquals(ME, triggers[1].text)
    NoErrors()
end)

test("someone else's guild message sends nothing", function()
    Fresh()
    Chat("CHAT_MSG_GUILD", "HEH", "Bob", OTHER)
    assertCount(0, triggers)
    NoErrors()
end)

test("a trigger opens the chorus and a keypress echoes", function()
    Fresh()
    PressKey()
    assertEquals(0, Echoes())
    Trigger(OTHER .. ":GUILD")
    assertTrue(keyFrame:IsShown())
    PressKey()
    assertEquals(1, Echoes())
    -- Once a second while the window is open.
    PressKey()
    assertEquals(1, Echoes())
    A_Admin.AdvanceTime(1)
    PressKey()
    assertEquals(2, Echoes())
    NoErrors()
end)

test("our echo coming back doesn't start another round", function()
    Fresh()
    Trigger(OTHER .. ":GUILD")
    PressKey()
    A_Admin.AdvanceTime(0.2)
    Chat("CHAT_MSG_GUILD", "HEH", "Me", ME)
    assertCount(0, triggers)
    NoErrors()
end)

test("the cat shows in the real Forever chat frame when the chorus ends", function()
    Fresh()
    Trigger(OTHER .. ":GUILD")
    A_Admin.AdvanceTime(4.9)
    assertEquals(0, Cats())
    A_Admin.AdvanceTime(0.2)
    assertEquals(1, Cats(1))
    for _, line in ipairs(lines) do
        if line.text:find("heh-cat", 1, true) then
            assertStartsWith(line.text, CHAT_GUILD_GET:format(""):sub(1, 10))
        end
    end
    NoErrors()
end)

test("a whisper chorus nobody echoed gets no cat", function()
    Fresh()
    Trigger(OTHER)
    A_Admin.AdvanceTime(6)
    assertEquals(0, Cats())
    NoErrors()
end)

test("a whisper chorus gets the cat once someone echoes in guild", function()
    Fresh()
    Trigger(OTHER)
    A_Admin.AdvanceTime(1)
    Chat("CHAT_MSG_GUILD", "HEH", "Cleo", "Player-1-00000003")
    A_Admin.AdvanceTime(5)
    assertEquals(1, Cats())
    NoErrors()
end)

test("no cat when no chat window shows guild chat", function()
    Fresh()
    ChatFrame_RemoveMessageGroup(ChatFrame1, "GUILD")
    Trigger(OTHER .. ":GUILD")
    A_Admin.AdvanceTime(6)
    assertEquals(0, Cats())
    ChatFrame_AddMessageGroup(ChatFrame1, "GUILD")
    NoErrors()
end)

test("a missed echo goes out just after the window, not much later", function()
    Fresh()
    Trigger(OTHER .. ":GUILD")
    A_Admin.AdvanceTime(7)
    PressKey()
    assertEquals(1, Echoes())
    Fresh()
    Trigger(OTHER .. ":GUILD")
    A_Admin.AdvanceTime(3600)
    PressKey()
    assertEquals(0, Echoes())
    NoErrors()
end)

test("the cat gets the chat timestamp when timestamps are on", function()
    Fresh()
    SetCVar("showTimestamps", "TS| ")
    local format = ChatFrameUtil.GetTimestampFormat()
    Trigger(OTHER .. ":GUILD")
    A_Admin.AdvanceTime(6)
    SetCVar("showTimestamps", "none")
    assertEquals("TS| ", format)
    assertEquals(1, Cats())
    for _, line in ipairs(lines) do
        if line.text:find("heh-cat", 1, true) then
            assertStartsWith(line.text, "TS| ")
        end
    end
    NoErrors()
end)

-- wow-ui-sim can't turn lockdown on, so stand in for it; HEH looks the function up on each call.
test("no echo during chat lockdown, the next keypress after it echoes", function()
    Fresh()
    local inLockdown = C_ChatInfo.InChatMessagingLockdown
    C_ChatInfo.InChatMessagingLockdown = function() return true end
    Trigger(OTHER .. ":GUILD")
    PressKey()
    local duringLockdown = Echoes()
    C_ChatInfo.InChatMessagingLockdown = inLockdown
    A_Admin.AdvanceTime(1)
    PressKey()
    assertEquals(0, duringLockdown)
    assertEquals(1, Echoes())
    NoErrors()
end)
