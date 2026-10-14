local PREFIX = "HEH_FUNNYECHO"
local ECHO_COOLDOWN = 1 -- seconds

local SendChat = C_ChatInfo.SendChatMessage or SendChatMessage

local lastEchoByGUID = {}
local pendingEchoes = 0
local playerGUID

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
        -- Already said in guild, skip our own echo.
        lastEchoByGUID[playerGUID] = GetTime()
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
    local now = GetTime()
    if now - (lastEchoByGUID[senderGUID] or 0) < ECHO_COOLDOWN then
        return
    end
    lastEchoByGUID[senderGUID] = now
    pendingEchoes = pendingEchoes + 1
    SendChat("HEH", "GUILD")
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif OUTGOING_EVENTS[event] then
        OnOutgoingChat(event, ...)
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
for event in pairs(OUTGOING_EVENTS) do
    frame:RegisterEvent(event)
end
