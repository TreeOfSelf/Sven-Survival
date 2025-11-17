bool survivalActive = false;
bool resetTimerStopped = true;
int currentTime = 0;

array<string> trackedSpawned;

// Track players with intact bodies (can't respawn until gibbed)
dictionary playerHasBody; // steamId -> bool

// Track player death locations
dictionary playerDeathLocations; // steamId -> Vector

CCVar@ cvar_enabled;
CCVar@ cvar_timer;
CCVar@ cvar_resetTime;
CCVar@ cvar_lateSpawn;

CScheduledFunction@ g_pThinkFunc;

//Init
void PluginInit() {
	g_Module.ScriptInfo.SetAuthor("Sebastian");
	g_Module.ScriptInfo.SetContactInfo("https://github.com/TreeOfSelf/Sven-Survival");
    g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
    g_Hooks.RegisterHook(Hooks::Player::PlayerSpawn, @PlayerSpawn);
	
    g_Hooks.RegisterHook(Hooks::Player::PlayerKilled, @PlayerKilled);
    g_Hooks.RegisterHook(Hooks::Player::ClientPutInServer, @ClientPutInServer);
    g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientDisconnect);



    @cvar_enabled = CCVar("enabled", 1, "Enable/Disable forced survival mode", ConCommandFlag::AdminOnly);
    @cvar_timer = CCVar("timer", 60, "Amount of time to count down to survival mode", ConCommandFlag::AdminOnly);
    @cvar_resetTime = CCVar("resetTime", 5, "Amount of time to reset map after last player dying", ConCommandFlag::AdminOnly);
    @cvar_lateSpawn = CCVar("lateSpawn", 1, "Enable/Disable late joining players to still spawn in", ConCommandFlag::AdminOnly);

    if (g_pThinkFunc !is null) {
		g_Scheduler.RemoveTimer(g_pThinkFunc);
		resetTimerStopped = true;
	}

    @g_pThinkFunc = g_Scheduler.SetInterval("displaySurvival", 1);

	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr !is null ) {
			Observer@ obs = plr.GetObserver();
			obs.StopObserver(true);
		} 
	}

    trackedSpawned.resize(0);
}

// Hooks
HookReturnCode MapChange( const string& in szNextMap ) {
	survivalActive = false;
	currentTime = 0;
	playerHasBody.deleteAll();
	playerDeathLocations.deleteAll();
	return HOOK_CONTINUE;
}

HookReturnCode PlayerSpawn( CBasePlayer@ pPlayer) {
    string steamId = g_EngineFuncs.GetPlayerAuthId(pPlayer.edict());

    if(survivalActive && g_SurvivalMode.IsEnabled()==false && cvar_enabled.GetInt() == 1) {
        // Check if player has an intact body (not gibbed)
        bool hasIntactBody = false;
        if (playerHasBody.exists(steamId)) {
            bool bodyState;
            playerHasBody.get(steamId, bodyState);
            hasIntactBody = bodyState;
        }

        // If player has an intact body, check if spawn has moved
        if (hasIntactBody && playerDeathLocations.exists(steamId)) {
            Vector deathLocation;
            playerDeathLocations.get(steamId, deathLocation);

            // Check if spawn area has moved away from the body
            if (hasSpawnMovedFrom(deathLocation)) {
                // Spawn has moved - allow respawn and clear body restriction
                playerHasBody[steamId] = false;
                playerDeathLocations.delete(steamId);
                g_PlayerFuncs.ClientPrint(pPlayer, HUD_PRINTTALK, "[Survival] Spawn area moved - you can now respawn.\n");
                // Continue with normal spawn logic below
            } else {
                // Body still exists and spawn hasn't moved - block respawn
                Observer@ obs = pPlayer.GetObserver();
                obs.SetObserverModeControlEnabled( true );
                obs.StartObserver(pPlayer.GetOrigin(), pPlayer.pev.angles, true);
                obs.SetObserverModeControlEnabled( true );
                pPlayer.pev.nextthink = 10000000.0;
                g_PlayerFuncs.ClientPrint(pPlayer, HUD_PRINTTALK, "[Survival] Your body is still intact. You cannot respawn until it is destroyed.\n");
                return HOOK_HANDLED;
            }
        }

        // Normal late spawn logic
        if (cvar_lateSpawn.GetInt() == 1 && trackedSpawned.find(steamId) < 0) {
            trackedSpawned.insertLast(steamId);
            return HOOK_CONTINUE;
        }

        // Block respawn for players who already spawned
        Observer@ obs = pPlayer.GetObserver();
        obs.SetObserverModeControlEnabled( true );
        obs.StartObserver(pPlayer.GetOrigin(), pPlayer.pev.angles, true);
        obs.SetObserverModeControlEnabled( true );
        pPlayer.pev.nextthink = 10000000.0;
        return HOOK_HANDLED;
    }

    return HOOK_CONTINUE;
}

HookReturnCode PlayerKilled( CBasePlayer@ pPlayer, CBaseEntity@ pAttacker, int iGib ) {
	string steamId = g_EngineFuncs.GetPlayerAuthId(pPlayer.edict());

	// Track body state: iGib == 0 means body is intact (not gibbed)
	if (iGib == 0) {
		playerHasBody[steamId] = true;
		// Store death location
		playerDeathLocations[steamId] = pPlayer.pev.origin;
	} else {
		// Player was gibbed - remove body restriction
		playerHasBody[steamId] = false;
		playerDeathLocations.delete(steamId);
	}

	if (resetTimerStopped && survivalActive  && checkPlayersDead()) {
		@g_pThinkFunc = g_Scheduler.SetInterval("mapChanger", cvar_resetTime.GetInt());
	}
	return HOOK_HANDLED;
}

HookReturnCode ClientPutInServer(CBasePlayer@ plr) {
	if (resetTimerStopped && survivalActive && checkPlayersDead()) {
		@g_pThinkFunc = g_Scheduler.SetInterval("mapChanger", cvar_resetTime.GetInt());
	}
	return HOOK_CONTINUE;
}

HookReturnCode ClientDisconnect(CBasePlayer@ plr) {
    // Clean up player's body state when they disconnect
    string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());
    playerHasBody.delete(steamId);
    playerDeathLocations.delete(steamId);

    if (resetTimerStopped && survivalActive && checkPlayersDead()) {
        @g_pThinkFunc = g_Scheduler.SetInterval("mapChanger", cvar_resetTime.GetInt());
    }
    return HOOK_CONTINUE;
}


// Main Functions
void MapInit() {
	g_Game.PrecacheMonster( "monster_gman", true );
	trackedSpawned.resize(0);
	playerHasBody.deleteAll();
	playerDeathLocations.deleteAll();
}

// Check if spawn points have moved away from a given location
// Returns true if no spawn points are near the location (spawn has moved)
bool hasSpawnMovedFrom(Vector deathLocation) {
	const float SPAWN_PROXIMITY_THRESHOLD = 512.0; // Units - adjust as needed

	// Find all potential spawn point entities
	array<string> spawnClassnames = {
		"info_player_start",
		"info_player_deathmatch",
		"info_player_coop"
	};

	for (uint i = 0; i < spawnClassnames.length(); i++) {
		CBaseEntity@ pEntity = null;
		while ((@pEntity = g_EntityFuncs.FindEntityByClassname(pEntity, spawnClassnames[i])) !is null) {
			// Calculate distance from death location to this spawn point
			float distance = (pEntity.pev.origin - deathLocation).Length();

			if (distance < SPAWN_PROXIMITY_THRESHOLD) {
				// Found a spawn point near death location - spawn hasn't moved
				return false;
			}
		}
	}

	// No spawn points found near death location - spawn has moved
	return true;
}

void displaySurvival() {
	if(g_SurvivalMode.IsEnabled()==false &&  cvar_enabled.GetInt() == 1) {
		if(currentTime<cvar_timer.GetInt()) {
			int oucurrentTime = cvar_timer.GetInt() - currentTime;
			for (int i = 1; i <= g_Engine.maxClients; i++) {
				CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
				if (plr !is null) {
					g_EngineFuncs.ClientPrintf(plr, print_center, "Survival mode starting in "+string(oucurrentTime)+" seconds");
				} 
			}
		}
		if(currentTime == cvar_timer.GetInt()) {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "Survival mode now active. No more respawning allowed.");
			survivalActive = true;
			if (resetTimerStopped && survivalActive  && checkPlayersDead()) {
				@g_pThinkFunc = g_Scheduler.SetInterval("mapChanger", cvar_resetTime.GetInt());
			}
			for (int i = 1; i <= g_Engine.maxClients; i++) {
				CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
				if (plr !is null && plr.IsAlive()==true && plr.IsConnected()) {
					string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());
					if (cvar_lateSpawn.GetInt() == 1 && trackedSpawned.find(steamId) < 0) {
						trackedSpawned.insertLast(steamId);        
					}
				}
			}
		}
	}
	currentTime+=1;
}

void mapChanger() {
	if(g_SurvivalMode.IsEnabled()==false &&  cvar_enabled.GetInt() == 1 && currentTime >= cvar_timer.GetInt()) {
		if(checkPlayersDead()) {
			g_EngineFuncs.ChangeLevel(string(g_Engine.mapname));
		}
	}
	g_Scheduler.RemoveTimer(g_pThinkFunc);
	resetTimerStopped = true;
}

bool checkPlayersDead() {
	int reset = 1;
	int playerHit = 0;
		for (int i = 1; i <= g_Engine.maxClients; i++) {
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
			if (plr !is null && plr.IsAlive()==true && plr.IsConnected()) {
				reset=0;
			} 
			if (plr !is null) {
				playerHit=1;
			}
		}
	if(reset==1 && playerHit==1) {
		return(true);
	}
	return(false);
}
