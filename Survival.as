bool survivalActive = false;
bool resetTimerStopped = true;
int currentTime = 0;

array<string> trackedSpawned;

// Track player death locations for spawn movement detection
dictionary playerDeathLocations; // steamId -> Vector

// Track last known spawn location to detect when it moves
Vector lastKnownSpawnLocation = Vector(0, 0, 0);

CCVar@ cvar_enabled;
CCVar@ cvar_timer;
CCVar@ cvar_resetTime;
CCVar@ cvar_lateSpawn;

CScheduledFunction@ g_pThinkFunc;
CScheduledFunction@ g_pCorpseCheckFunc;

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
    @g_pCorpseCheckFunc = g_Scheduler.SetInterval("CheckCorpsesNearSpawn", 1);

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
	playerDeathLocations.deleteAll();
	return HOOK_CONTINUE;
}

HookReturnCode PlayerSpawn( CBasePlayer@ pPlayer) {
    string steamId = g_EngineFuncs.GetPlayerAuthId(pPlayer.edict());

    if(survivalActive && g_SurvivalMode.IsEnabled()==false && cvar_enabled.GetInt() == 1) {
        // Check if player has a corpse in the world
        CBaseEntity@ pCorpse = FindPlayerCorpse(pPlayer);

        // If player has a corpse, block respawn - don't move it, leave it where it is
        if (pCorpse !is null) {
            // Block respawn attempt - corpse stays at death location
            Observer@ obs = pPlayer.GetObserver();
            obs.SetObserverModeControlEnabled( true );
            obs.StartObserver(pPlayer.GetOrigin(), pPlayer.pev.angles, true);
            obs.SetObserverModeControlEnabled( true );
            pPlayer.pev.nextthink = 10000000.0;
            g_PlayerFuncs.ClientPrint(pPlayer, HUD_PRINTTALK, "[Survival] You have a body that needs revival. Cannot respawn.\n");
            return HOOK_HANDLED;
        }

        // No corpse (gibbed) - allow late spawn logic
        if (cvar_lateSpawn.GetInt() == 1 && trackedSpawned.find(steamId) < 0) {
            trackedSpawned.insertLast(steamId);
            return HOOK_CONTINUE; // Game will create corpse at spawn naturally
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

	// Store death location for spawn movement detection
	playerDeathLocations[steamId] = pPlayer.pev.origin;

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
    // Clean up player's death location when they disconnect
    string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());
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
	playerDeathLocations.deleteAll();
}

// Find a player's corpse entity by searching for bodyque entities
// Returns the corpse entity if found, null otherwise
// Based on Half-Life source: corpses store player entindex in pev.renderamt
CBaseEntity@ FindPlayerCorpse(CBasePlayer@ pPlayer) {
	if (pPlayer is null)
		return null;

	int playerEntIndex = pPlayer.entindex();

	// Search all bodyque entities (player corpses)
	CBaseEntity@ pCorpse = null;
	while ((@pCorpse = g_EntityFuncs.FindEntityByClassname(pCorpse, "bodyque")) !is null) {
		// The corpse stores the player's entity index in renderamt
		if (int(pCorpse.pev.renderamt) == playerEntIndex) {
			return pCorpse;
		}
	}

	return null; // No corpse found
}

// Get a spawn point location
// Returns the origin of the first spawn point found
Vector GetSpawnPoint() {
	array<string> spawnClassnames = {
		"info_player_deathmatch",
		"info_player_start",
		"info_player_coop"
	};

	for (uint i = 0; i < spawnClassnames.length(); i++) {
		CBaseEntity@ pSpawn = g_EntityFuncs.FindEntityByClassname(null, spawnClassnames[i]);
		if (pSpawn !is null) {
			return pSpawn.pev.origin;
		}
	}

	// Fallback to world origin if no spawn found
	return Vector(0, 0, 0);
}

// Check if spawn points have moved away from a given location
// Returns true if no spawn points are near the location (spawn has moved)
bool hasSpawnMovedFrom(Vector location) {
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
			// Calculate distance from location to this spawn point
			float distance = (pEntity.pev.origin - location).Length();

			if (distance < SPAWN_PROXIMITY_THRESHOLD) {
				// Found a spawn point near location - spawn hasn't moved
				return false;
			}
		}
	}

	// No spawn points found near location - spawn has moved
	return true;
}

// Periodic check to automatically move corpses if spawn has moved
// Runs every second to ensure corpses at spawn stay with spawn
void CheckCorpsesNearSpawn() {
	if (!survivalActive || g_SurvivalMode.IsEnabled() || cvar_enabled.GetInt() != 1)
		return;

	const float SPAWN_PROXIMITY_THRESHOLD = 512.0;

	// Get current spawn location
	Vector currentSpawn = GetSpawnPoint();

	// Check if spawn has moved significantly
	float spawnMovement = (currentSpawn - lastKnownSpawnLocation).Length();

	// Initialize last known spawn if this is first check
	if (lastKnownSpawnLocation.x == 0 && lastKnownSpawnLocation.y == 0 && lastKnownSpawnLocation.z == 0) {
		lastKnownSpawnLocation = currentSpawn;
		return;
	}

	// If spawn hasn't moved, nothing to do
	if (spawnMovement < 100.0) // Small threshold for spawn movement detection
		return;

	// Spawn has moved! Find corpses that were near the OLD spawn and move them
	CBaseEntity@ pCorpse = null;
	while ((@pCorpse = g_EntityFuncs.FindEntityByClassname(pCorpse, "bodyque")) !is null) {
		// Check if this corpse is near the OLD spawn location
		float distanceToOldSpawn = (pCorpse.pev.origin - lastKnownSpawnLocation).Length();

		if (distanceToOldSpawn < SPAWN_PROXIMITY_THRESHOLD) {
			// Corpse was at old spawn - move it to new spawn
			g_EntityFuncs.SetOrigin(pCorpse, currentSpawn);

			// Notify the player whose corpse this is
			int playerEntIndex = int(pCorpse.pev.renderamt);
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(playerEntIndex);
			if (plr !is null && !plr.IsAlive()) {
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Survival] Spawn moved - your body has been relocated.\n");
			}
		}
	}

	// Update last known spawn location
	lastKnownSpawnLocation = currentSpawn;
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
