-- Token authentication
-- Copyright (C) 2015 Atlassian

local basexx = require "basexx";
local have_async, async = pcall(require, "util.async");
local hex = require "util.hex";
local jwt = require "luajwtjitsi";
local http = require "net.http";
local jid = require "util.jid";
local json = require "cjson";
local path = require "util.paths";
local sha256 = require "util.hashes".sha256;
local timer = require "util.timer";

local http_timeout = 30;
local http_headers = {
    ["User-Agent"] = "Prosody ("..prosody.version.."; "..prosody.platform..")"
};

-- TODO: Figure out a less arbitrary default cache size.
local cacheSize = module:get_option_number("jwt_pubkey_cache_size", 128);
local cache = require"util.cache".new(cacheSize);

local Util = {}
Util.__index = Util

--- Constructs util class for token verifications.
-- Constructor that uses the passed module to extract all the
-- needed configurations.
-- If confuguration is missing returns nil
-- @param module the module in which options to check for configs.
-- @return the new instance or nil
function Util.new(module)
    local self = setmetatable({}, Util)

    self.appId = module:get_option_string("app_id");
    self.appSecret = module:get_option_string("app_secret");
    self.asapKeyServer = module:get_option_string("asap_key_server");
    self.allowEmptyToken = module:get_option_boolean("allow_empty_token");

    --[[
        Multidomain can be supported in some deployments. In these deployments
        there is a virtual conference muc, which address contains the subdomain
        to use. Those deployments are accessible
        by URL https://domain/subdomain.
        Then the address of the room will be:
        roomName@conference.subdomain.domain. This is like a virtual address
        where there is only one muc configured by default with address:
        conference.domain and the actual presentation of the room in that muc
        component is [subdomain]roomName@conference.domain.
        These setups relay on configuration 'muc_domain_base' which holds
        the main domain and we use it to substract subdomains from the
        virtual addresses.
        The following confgurations are for multidomain setups and domain name
        verification:
     --]]

    -- optional parameter for custom muc component prefix,
    -- defaults to "conference"
    self.muc_domain_prefix = module:get_option_string(
        "muc_mapper_domain_prefix", "conference");
    -- domain base, which is the main domain used in the deployment,
    -- the main VirtualHost for the deployment
    self.muc_domain_base = module:get_option_string("muc_mapper_domain_base");
    -- The "real" MUC domain that we are proxying to
    if self.muc_domain_base then
        self.muc_domain = module:get_option_string(
            "muc_mapper_domain",
            self.muc_domain_prefix.."."..self.muc_domain_base);
    end
    -- whether domain name verification is enabled, by default it is disabled
    self.enableDomainVerification = module:get_option_boolean(
        "enable_domain_verification", false);

    if self.allowEmptyToken == true then
        module:log("warn", "WARNING - empty tokens allowed");
    end

    if self.appId == nil then
        module:log("error", "'app_id' must not be empty");
        return nil;
    end

    if self.appSecret == nil and self.asapKeyServer == nil then
        module:log("error", "'app_secret' or 'asap_key_server' must be specified");
        return nil;
    end

    --array of accepted issuers: by default only includes our appId
    self.acceptedIssuers = module:get_option_array('asap_accepted_issuers',{self.appId})

    --array of accepted audiences: by default only includes our appId
    self.acceptedAudiences = module:get_option_array('asap_accepted_audiences',{'*'})

    if self.asapKeyServer and not have_async then
        module:log("error", "requires a version of Prosody with util.async");
        return nil;
    end

    return self
end

--- Returns the public key by keyID
-- @param keyId the key ID to request
-- @return the public key (the content of requested resource) or nil
function Util:get_public_key(keyId)
    local content = cache:get(keyId);
    if content == nil then
        -- If the key is not found in the cache.
        module:log("debug", "Cache miss for key: "..keyId);
        local code;
        local wait, done = async.waiter();
        local function cb(content_, code_, response_, request_)
            content, code = content_, code_;
            if code == 200 or code == 204 then
                cache:set(keyId, content);
            end
            done();
        end
        local keyurl = path.join(self.asapKeyServer, hex.to(sha256(keyId))..'.pem');
        module:log("debug", "Fetching public key from: "..keyurl);

        -- We hash the key ID to work around some legacy behavior and make
        -- deployment easier. It also helps prevent directory
        -- traversal attacks (although path cleaning could have done this too).
        local request = http.request(keyurl, {
            headers = http_headers or {},
            method = "GET"
        }, cb);

        -- TODO: Is the done() call racey? Can we cancel this if the request
        --       succeedes?
        local function cancel()
            -- TODO: This check is racey. Not likely to be a problem, but we should
            --       still stick a mutex on content / code at some point.
            if code == nil then
                http.destroy_request(request);
                done();
            end
        end
        timer.add_task(http_timeout, cancel);
        wait();

        if code == 200 or code == 204 then
            return content;
        end
    else
        -- If the key is in the cache, use it.
        module:log("debug", "Cache hit for key: "..keyId);
        return content;
    end

    return nil;
end

--- Verifies issuer part of token
-- @param 'iss' claim from the token to verify
-- @return nil and error string or true for accepted claim
function Util:verify_issuer(issClaim)
    for i, iss in ipairs(self.acceptedIssuers) do
        if issClaim == iss then
            --claim matches an accepted issuer so return success
            return true;
        end
    end
    --if issClaim not found in acceptedIssuers, fail claim
    return nil, "Invalid issuer ('iss' claim)";
end

--- Verifies audience part of token
-- @param 'aud' claim from the token to verify
-- @return nil and error string or true for accepted claim
function Util:verify_audience(audClaim)
    for i, aud in ipairs(self.acceptedAudiences) do
        if aud == '*' then
            --* indicates to accept any audience in the claims so return success
            return true;
        end
        if audClaim == aud then
            --claim matches an accepted audience so return success
            return true;
        end
    end
    --if issClaim not found in acceptedIssuers, fail claim
    return nil, "Invalid audience ('aud' claim)";
end

--- Verifies token
-- @param token the token to verify
-- @param secret the secret to use to verify token
-- @return nil and error or the extracted claims from the token
function Util:verify_token(token, secret)
    local claims, err = jwt.decode(token, secret, true);
    if claims == nil then
        return nil, err;
    end

    local alg = claims["alg"];
    if alg ~= nil and (alg == "none" or alg == "") then
        return nil, "'alg' claim must not be empty";
    end

    local issClaim = claims["iss"];
    if issClaim == nil then
        return nil, "'iss' claim is missing";
    end
    --check the issuer against the accepted list
    local issCheck, issCheckErr = self:verify_issuer(issClaim);
    if issCheck == nil then
        return nil, issCheckErr;
    end

    local roomClaim = claims["room"];
    if roomClaim == nil then
        return nil, "'room' claim is missing";
    end

    local audClaim = claims["aud"];
    if audClaim == nil then
        return nil, "'aud' claim is missing";
    end
    --check the audience against the accepted list
    local audCheck, audCheckErr = self:verify_audience(audClaim);
    if audCheck == nil then
        return nil, audCheckErr;
    end

    return claims;
end

--- Verifies token and process needed values to be stored in the session.
-- Token is obtained from session.auth_token.
-- Stores in session the following values:
-- session.jitsi_meet_room - the room name value from the token
-- session.jitsi_meet_domain - the domain name value from the token
-- session.jitsi_meet_context_user - the user details from the token
-- session.jitsi_meet_context_group - the group value from the token
-- session.jitsi_meet_context_features - the features value from the token
-- @param session the current session
-- @return false and error
function Util:process_and_verify_token(session)

    if session.auth_token == nil then
        if self.allowEmptyToken then
            return true;
        else
            return false, "not-allowed", "token required";
        end
    end

    local pubKey;
    if self.asapKeyServer and session.auth_token ~= nil then
        local dotFirst = session.auth_token:find("%.");
        if not dotFirst then return nil, "Invalid token" end
        local header = json.decode(basexx.from_url64(session.auth_token:sub(1,dotFirst-1)));
        local kid = header["kid"];
        if kid == nil then
            return false, "not-allowed", "'kid' claim is missing";
        end
        pubKey = self:get_public_key(kid);
        if pubKey == nil then
            return false, "not-allowed", "could not obtain public key";
        end
    end

    -- now verify the whole token
    local claims, msg;
    if self.asapKeyServer then
        claims, msg = self:verify_token(session.auth_token, pubKey);
    else
        claims, msg = self:verify_token(session.auth_token, self.appSecret);
    end
    if claims ~= nil then
        -- Binds room name to the session which is later checked on MUC join
        session.jitsi_meet_room = claims["room"];
        -- Binds domain name to the session
        session.jitsi_meet_domain = claims["sub"];

        -- Binds the user details to the session if available
        if claims["context"] ~= nil then
          if claims["context"]["user"] ~= nil then
            session.jitsi_meet_context_user = claims["context"]["user"];
          end

          if claims["context"]["group"] ~= nil then
            -- Binds any group details to the session
            session.jitsi_meet_context_group = claims["context"]["group"];
          end

          if claims["context"]["features"] ~= nil then
            -- Binds any features details to the session
            session.jitsi_meet_context_features = claims["context"]["features"];
          end
        end
        return true;
    else
        return false, "not-allowed", msg;
    end
end

--- Verifies room name and domain if necesarry.
-- Checks configs and if necessary checks the room name extracted from
-- room_address against the one saved in the session when token was verified.
-- Also verifies domain name from token against the domain in the room_address,
-- if enableDomainVerification is enabled.
-- @param session the current session
-- @param room_address the whole room address as received
-- @return returns true in case room was verified or there is no need to verify
--         it and returns false in case verification was processed
--         and was not successful
function Util:verify_room(session, room_address)
    if self.allowEmptyToken and session.auth_token == nil then
        module:log(
            "debug",
            "Skipped room token verification - empty tokens are allowed");
        return true;
    end

    -- extract room name using all chars, except the not allowed ones
    local room,_,_ = jid.split(room_address);
    if room == nil then
        log("error",
            "Unable to get name of the MUC room ? to: %s", room_address);
        return true;
    end

    local auth_room = session.jitsi_meet_room;
    if not self.enableDomainVerification then
        -- if auth_room is missing, this means user is anonymous (no token for
        -- its domain) we let it through, jicofo is verifying creation domain
        if auth_room and room ~= string.lower(auth_room) and auth_room ~= '*' then
            return false;
        end

        return true;
    end

    local room_address_to_verify = jid.bare(room_address);
    local room_node = jid.node(room_address);
    -- parses bare room address, for multidomain expected format is:
    -- [subdomain]roomName@conference.domain
    local target_subdomain, target_room = room_node:match("^%[([^%]]+)%](.+)$");

    -- if we have '*' as room name in token, this means all rooms are allowed
    -- so we will use the actual name of the room when constructing strings
    -- to verify subdomains and domains to simplify checks
    local room_to_check;
    if auth_room == '*' then
        -- authorized for accessing any room assign to room_to_check the actual
        -- room name
        if target_room ~= nil then
            -- we are in multidomain mode and we were able to extract room name
            room_to_check = target_room;
        else
            -- no target_room, room_address_to_verify does not contain subdomain
            -- so we get just the node which is the room name
            room_to_check = room_node;
        end
    else
        room_to_check = auth_room;
    end

    local auth_domain = session.jitsi_meet_domain;
    if target_subdomain then
        -- from this point we depend on muc_domain_base,
        -- deny access if option is missing
        if not self.muc_domain_base then
            module:log("warn", "No 'muc_domain_base' option set, denying access!");
            return false;
        end

        return room_address_to_verify == jid.join(
            "["..auth_domain.."]"..string.lower(room_to_check), self.muc_domain);
    else
        -- we do not have a domain part (multidomain is not enabled)
        -- verify with info from the token
        return room_address_to_verify == jid.join(
            string.lower(room_to_check), self.muc_domain_prefix.."."..auth_domain);
    end
end

return Util;
