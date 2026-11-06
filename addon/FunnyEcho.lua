local PREFIX = "HEH_FUNNYECHO"
-- Appended to the trigger when the HEH was said in guild chat. v2.0.0 never adds it.
local GUILD_TAG = ":GUILD"
-- The first HEH opens a chorus; while it's open, each player may echo once per interval.
local CHORUS_WINDOW = 5 -- seconds
local ECHO_INTERVAL = 1 -- seconds
-- An echo that hasn't come back by then was dropped (spam filter, muted rank, secret message).
-- Generous, so a lagged echo isn't mistaken for a new HEH.
local ECHO_CONFIRM_TIMEOUT = 10 -- seconds
-- Missed the window: our first echo still goes out on a keypress this soon after, not hours later.
local LATE_ECHO_GRACE = 5 -- seconds

local SendChat = C_ChatInfo.SendChatMessage or SendChatMessage

-- Send times of our echoes still waiting to come back as CHAT_MSG_GUILD, oldest first.
local pendingEchoes = {}
local playerGUID

local chorusEndsAt
local lastEchoAt
local echoedThisChorus = false
-- Last time anyone's HEH showed up in guild chat; a chorus with none gets no cat.
local lastGuildHehAt

-- Echoes wait for a keypress, since sending chat may need a hardware event.
local echoQueued = false
local sendingEcho = false
local echoBlocked = false

local OUTGOING_EVENTS = {
    CHAT_MSG_SAY = true,
    CHAT_MSG_YELL = true,
    CHAT_MSG_EMOTE = true,
    CHAT_MSG_GUILD = true,
    CHAT_MSG_OFFICER = true,
    CHAT_MSG_PARTY = true,
    CHAT_MSG_PARTY_LEADER = true,
    CHAT_MSG_RAID = true,
    CHAT_MSG_RAID_LEADER = true,
    CHAT_MSG_RAID_WARNING = true,
    CHAT_MSG_INSTANCE_CHAT = true,
    CHAT_MSG_INSTANCE_CHAT_LEADER = true,
    CHAT_MSG_WHISPER_INFORM = true,
    CHAT_MSG_BN_WHISPER_INFORM = true,
    CHAT_MSG_CHANNEL = true,
}

local ALWAYS_OWN = {
    CHAT_MSG_WHISPER_INFORM = true,
    CHAT_MSG_BN_WHISPER_INFORM = true,
}

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

local function SendTrigger(fromGuild)
    if not IsInGuild() then
        return
    end
    C_ChatInfo.SendAddonMessage(PREFIX, fromGuild and playerGUID .. GUILD_TAG or playerGUID, "GUILD")
end

-- Takes the oldest unexpired pending echo, so a dropped echo can't swallow a real HEH later.
local function ConsumePendingEcho()
    local now = GetTime()
    while pendingEchoes[1] and now - pendingEchoes[1] > ECHO_CONFIRM_TIMEOUT do
        table.remove(pendingEchoes, 1)
    end
    if pendingEchoes[1] then
        table.remove(pendingEchoes, 1)
        return true
    end
    return false
end

local function InChorus()
    return chorusEndsAt ~= nil and GetTime() < chorusEndsAt
end

-- Chat sends are restricted during chat messaging lockdown (Forever, 12.0+).
local function InChatLockdown()
    return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown()
end

-- ADDON_ACTION_BLOCKED fires during the blocked call, so we can tell whether it went out.
-- Blocks are usually temporary (combat, instance lockdown), so the next chorus tries again.
local function TrySendEcho()
    sendingEcho, echoBlocked = true, false
    table.insert(pendingEchoes, GetTime())
    SendChat("HEH", "GUILD")
    sendingEcho = false
    if echoBlocked then
        table.remove(pendingEchoes)
        return false
    end
    lastEchoAt = GetTime()
    echoedThisChorus = true
    return true
end

-- Keyboard only (no mouse), and keys propagate, so it never swallows input.
local queueFrame = CreateFrame("Frame")
queueFrame:Hide()
queueFrame:EnableKeyboard(true)
queueFrame:SetPropagateKeyboardInput(true)

local function StopQueue()
    echoQueued = false
    queueFrame:Hide()
end

-- Must run from a hardware event.
local function OnKeyDown()
    -- Stay queued through a lockdown, so a keypress after it ends can still echo.
    if not echoQueued or InChatLockdown() then
        return
    end
    if not InChorus() then
        -- Window closed: our first echo still goes out, but no more repeats.
        StopQueue()
        if not echoedThisChorus and GetTime() < chorusEndsAt + LATE_ECHO_GRACE then
            TrySendEcho()
        end
        return
    end
    if lastEchoAt and GetTime() - lastEchoAt < ECHO_INTERVAL then
        return
    end
    -- Stay queued so later keypresses can repeat while the window is open.
    if not TrySendEcho() then
        StopQueue()
    end
end

queueFrame:SetScript("OnKeyDown", OnKeyDown)

-- Shown locally (only to us) when a chorus ends, styled like a guild message.
local CAT_SENDER = "Heh Heheh"
local CAT_TEXTURE = "|TInterface\\AddOns\\HEH\\heh-cat:64:64|t"

-- Forever keeps these in ChatFrameUtil and TimeUtil; older clients have them as globals.
local function TimestampFormat()
    if ChatFrameUtil and ChatFrameUtil.GetTimestampFormat then
        return ChatFrameUtil.GetTimestampFormat()
    end
    return CHAT_TIMESTAMP_FORMAT
end

local function ShowCat()
    local link = "|Hplayer:" .. CAT_SENDER .. "|h[" .. CAT_SENDER .. "]|h"
    local text = (CHAT_GUILD_GET or "|Hchannel:GUILD|h[Guild]|h %s: "):format(link) .. CAT_TEXTURE
    local timestampFormat = TimestampFormat()
    if type(timestampFormat) == "string" then
        local betterDate = TimeUtil and TimeUtil.BetterDate or BetterDate
        text = betterDate(timestampFormat, time()) .. text
    end
    local info = ChatTypeInfo.GUILD
    for i = 1, NUM_CHAT_WINDOWS do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame.messageTypeList and tContains(chatFrame.messageTypeList, "GUILD") then
            chatFrame:AddMessage(text, info.r, info.g, info.b, info.id)
        end
    end
end

local function OpenChorus(fromGuild)
    local openedAt = GetTime()
    chorusEndsAt = openedAt + CHORUS_WINDOW
    lastEchoAt = nil
    echoedThisChorus = false
    echoQueued = true
    queueFrame:Show()
    -- A HEH said outside guild chat (whispers, party, ...) only shows up there if someone echoes, and
    -- echoes wait for a keypress. No cat for a chorus nobody saw, it'd come out of nowhere.
    C_Timer.After(CHORUS_WINDOW, function()
        if fromGuild or (lastGuildHehAt and lastGuildHehAt >= openedAt) then
            ShowCat()
        end
    end)
end

-- Any sender, us included.
local function OnGuildChat(msg)
    if not IsSecret(msg) and msg == "HEH" then
        lastGuildHehAt = GetTime()
    end
end

local function OnOutgoingChat(event, msg, ...)
    -- Secret values (12.0+) can't be inspected.
    if IsSecret(msg) then
        return
    end
    if not ALWAYS_OWN[event] then
        local guid = select(11, ...)
        if IsSecret(guid) or guid ~= playerGUID then
            return
        end
    end
    if msg ~= "HEH" then
        return
    end
    if event == "CHAT_MSG_GUILD" then
        -- Our own echo, don't start another round.
        if ConsumePendingEcho() then
            return
        end
        -- Said in guild ourselves: it counts as our echo for this chorus.
        if not InChorus() then
            OpenChorus(true)
        end
        lastEchoAt = GetTime()
        echoedThisChorus = true
    end
    SendTrigger(event == "CHAT_MSG_GUILD")
end

-- Addon messages only carry the sender's name, so the trigger carries their GUID.
local function OnAddonMessage(prefix, trigger, channel)
    if prefix ~= PREFIX or channel ~= "GUILD" or IsSecret(trigger) then
        return
    end
    if not trigger:find("^Player%-") then
        return
    end
    -- HEHs during an open chorus are part of it.
    if InChorus() then
        return
    end
    OpenChorus(trigger:sub(-#GUILD_TAG) == GUILD_TAG)
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "ADDON_ACTION_BLOCKED" then
        if sendingEcho and ... == "HEH" then
            echoBlocked = true
        end
    elseif OUTGOING_EVENTS[event] then
        if event == "CHAT_MSG_GUILD" then
            OnGuildChat(...)
        end
        OnOutgoingChat(event, ...)
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
for event in pairs(OUTGOING_EVENTS) do
    frame:RegisterEvent(event)
end
