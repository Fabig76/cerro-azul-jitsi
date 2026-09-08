admins = {
    

    

    "focus@auth.meet.urbcerroazul.com",
    "jvb@auth.meet.urbcerroazul.com"
}

unlimited_jids = {
    "focus@auth.meet.urbcerroazul.com",
    "jvb@auth.meet.urbcerroazul.com"
}

plugin_paths = { "/prosody-plugins/", "/prosody-plugins-custom" }

muc_mapper_domain_base = "meet.urbcerroazul.com";
muc_mapper_domain_prefix = "muc";

http_default_host = "meet.urbcerroazul.com"

external_service_secret = "f402689c7a94bf1d56ac6435846a1737";

external_services = {
        { type = "turn", host = "meet.urbcerroazul.com", port = 443, transport = "tcp", secret = true, ttl = 86400, algorithm = "turn" }
};





consider_bosh_secure = true;
consider_websocket_secure = true;



VirtualHost "meet.urbcerroazul.com"

    authentication = "jitsi-anonymous"

    ssl = {
        key = "/config/certs/meet.urbcerroazul.com.key";
        certificate = "/config/certs/meet.urbcerroazul.com.crt";
    }
    modules_enabled = {
        "bosh";
        
        "websocket";
        "smacks"; -- XEP-0198: Stream Management
        
        "pubsub";
        "ping";
        "speakerstats";
        "conference_duration";
        "room_metadata";
        
        "end_conference";
        
        
        "external_services";
        
        
        "muc_lobby_rooms";
        
        
        "muc_breakout_rooms";
        
        
        "av_moderation";
        
        
        
        
        
    }

    main_muc = "muc.meet.urbcerroazul.com"
    room_metadata_component = "metadata.meet.urbcerroazul.com"
    
    lobby_muc = "lobby.meet.urbcerroazul.com"
    
    

    

    
    breakout_rooms_muc = "breakout.meet.urbcerroazul.com"
    

    speakerstats_component = "speakerstats.meet.urbcerroazul.com"
    conference_duration_component = "conferenceduration.meet.urbcerroazul.com"

    
    end_conference_component = "endconference.meet.urbcerroazul.com"
    

    
    av_moderation_component = "avmoderation.meet.urbcerroazul.com"
    

    c2s_require_encryption = false

    

    

VirtualHost "auth.meet.urbcerroazul.com"
    ssl = {
        key = "/config/certs/auth.meet.urbcerroazul.com.key";
        certificate = "/config/certs/auth.meet.urbcerroazul.com.crt";
    }
    modules_enabled = {
        "limits_exception";
        "ping";
    }
    authentication = "internal_hashed"



Component "internal-muc.meet.urbcerroazul.com" "muc"
    storage = "memory"
    modules_enabled = {
        "ping";
        }
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "muc.meet.urbcerroazul.com" "muc"
    restrict_room_creation = true
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        
        "polls";
        "muc_domain_mapper";
        
        "muc_password_whitelist";
    }

    -- The size of the cache that saves state for IP addresses
    rate_limit_cache_size = 10000;

    muc_room_cache_size = 10000
    muc_room_locking = false
    muc_room_default_public_jids = true
    
    muc_password_whitelist = {
        "focus@auth.meet.urbcerroazul.com"
    }

Component "focus.meet.urbcerroazul.com" "client_proxy"
    target_address = "focus@auth.meet.urbcerroazul.com"

Component "speakerstats.meet.urbcerroazul.com" "speakerstats_component"
    muc_component = "muc.meet.urbcerroazul.com"

Component "conferenceduration.meet.urbcerroazul.com" "conference_duration_component"
    muc_component = "muc.meet.urbcerroazul.com"


Component "endconference.meet.urbcerroazul.com" "end_conference"
    muc_component = "muc.meet.urbcerroazul.com"



Component "avmoderation.meet.urbcerroazul.com" "av_moderation_component"
    muc_component = "muc.meet.urbcerroazul.com"



Component "lobby.meet.urbcerroazul.com" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_allow_persistent = false
    muc_room_cache_size = 10000
    muc_room_locking = false
    muc_room_default_public_jids = true
    modules_enabled = {
        }

    


Component "breakout.meet.urbcerroazul.com" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_cache_size = 10000
    muc_room_locking = false
    muc_room_default_public_jids = true
    muc_room_allow_persistent = false
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
        "polls";
        }


Component "metadata.meet.urbcerroazul.com" "room_metadata_component"
    muc_component = "muc.meet.urbcerroazul.com"
    breakout_rooms_component = "breakout.meet.urbcerroazul.com"



