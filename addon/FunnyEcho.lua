local PREFIX = "HEH_FUNNYECHO"
-- The first HEH opens a chorus; while it's open, each player may echo once per interval.
local CHORUS_WINDOW = 5 -- seconds
local ECHO_INTERVAL = 1 -- seconds

local SendChat = C_ChatInfo.SendChatMessage or SendChatMessage

local pendingEchoes = 0
local playerGUID

local chorusEndsAt
local lastEchoAt
local echoedThisChorus = false

-- Echoes wait for a keypress, since sending chat may need a hardware event.
local echoQueued = false
local sendingEcho = false
local echoBlocked = false
-- Set once a send is blocked, so a restricted account errors once per session.
local echoDisabled = false

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

local function SendTrigger()
    if not IsInGuild() then
        return
    end
    C_ChatInfo.SendAddonMessage(PREFIX, playerGUID, "GUILD")
end

local function InChorus()
    return chorusEndsAt ~= nil and GetTime() < chorusEndsAt
end

-- ADDON_ACTION_BLOCKED fires during the blocked call, so we can tell whether it went out.
local function TrySendEcho()
    sendingEcho, echoBlocked = true, false
    pendingEchoes = pendingEchoes + 1
    SendChat("HEH", "GUILD")
    sendingEcho = false
    if echoBlocked then
        pendingEchoes = pendingEchoes - 1
        echoDisabled = true
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
    if not echoQueued then
        return
    end
    if not InChorus() then
        -- Window closed: our first echo still goes out, but no more repeats.
        StopQueue()
        if not echoedThisChorus then
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

local function ShowCat()
    local link = "|Hplayer:" .. CAT_SENDER .. "|h[" .. CAT_SENDER .. "]|h"
    local text = (CHAT_GUILD_GET or "|Hchannel:GUILD|h[Guild]|h %s: "):format(link) .. CAT_TEXTURE
    if type(CHAT_TIMESTAMP_FORMAT) == "string" then
        text = BetterDate(CHAT_TIMESTAMP_FORMAT, time()) .. text
    end
    local info = ChatTypeInfo.GUILD
    local shown = false
    for i = 1, NUM_CHAT_WINDOWS do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame.messageTypeList and tContains(chatFrame.messageTypeList, "GUILD") then
            chatFrame:AddMessage(text, info.r, info.g, info.b, info.id)
            shown = true
        end
    end
    if not shown then
        DEFAULT_CHAT_FRAME:AddMessage(text, info.r, info.g, info.b, info.id)
    end
end

local function OpenChorus()
    chorusEndsAt = GetTime() + CHORUS_WINDOW
    lastEchoAt = nil
    echoedThisChorus = false
    if not echoDisabled then
        echoQueued = true
        queueFrame:Show()
    end
    -- A new chorus can only open after this one ends, so this timer always matches it.
    C_Timer.After(CHORUS_WINDOW, ShowCat)
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
        if pendingEchoes > 0 then
            pendingEchoes = pendingEchoes - 1
            return
        end
        -- Said in guild ourselves: it counts as our echo for this chorus.
        if not InChorus() then
            OpenChorus()
        end
        lastEchoAt = GetTime()
        echoedThisChorus = true
    end
    SendTrigger()
end

-- Addon messages only carry the sender's name, so the trigger carries their GUID.
local function OnAddonMessage(prefix, senderGUID, channel)
    if prefix ~= PREFIX or channel ~= "GUILD" or IsSecret(senderGUID) then
        return
    end
    if not senderGUID:find("^Player%-") then
        return
    end
    -- HEHs during an open chorus are part of it.
    if InChorus() then
        return
    end
    OpenChorus()
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
        OnOutgoingChat(event, ...)
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
for event in pairs(OUTGOING_EVENTS) do
    frame:RegisterEvent(event)
end
