// Track last known spawn location to detect when it moves
Vector lastKnownSpawnLocation = Vector(0, 0, 0);

// Track players who have spawned at least once
array<string> hasSpawnedBefore;

// Track players who were connected when the map started
array<string> wasConnectedAtMapStart;

// Store if map already had survival support before we enabled it
bool mapAlreadyHadSurvival = false;

CCVar@ cvar_enabled;
CCVar@ cvar_lateSpawn;

CScheduledFunction@ g_pCorpseCheckFunc;
CScheduledFunction@ g_pBodyCheckFunc;

//Init
void PluginInit() {
	g_Module.ScriptInfo.SetAuthor("Sebastian");
	g_Module.ScriptInfo.SetContactInfo("https://github.com/TreeOfSelf/Sven-Survival");
	
	g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);

	@cvar_enabled = CCVar("enabled", 1, "Enable/Disable survival mode", ConCommandFlag::AdminOnly);
	@cvar_lateSpawn = CCVar("lateSpawn", 1, "Enable/Disable late joining players to spawn in", ConCommandFlag::AdminOnly);

	@g_pCorpseCheckFunc = g_Scheduler.SetInterval("MoveCorpsesToNewSpawn", 1, g_Scheduler.REPEAT_INFINITE_TIMES);
	@g_pBodyCheckFunc = g_Scheduler.SetInterval("CheckPlayersWithoutBodies", 1, g_Scheduler.REPEAT_INFINITE_TIMES);
}

void MapActivate() {
	// Store if map already had survival support BEFORE we enable it
	mapAlreadyHadSurvival = g_SurvivalMode.MapSupportEnabled();
	
	if (cvar_enabled.GetInt() == 1) {
		g_SurvivalMode.EnableMapSupport();
		g_SurvivalMode.Activate();
	}
	
	// Record who was connected when the map started
	RecordConnectedPlayers();
}

// Hooks
HookReturnCode MapChange(const string& in szNextMap) {
	hasSpawnedBefore.resize(0);
	wasConnectedAtMapStart.resize(0);
	lastKnownSpawnLocation = Vector(0, 0, 0);
	mapAlreadyHadSurvival = false;
	return HOOK_CONTINUE;
}

// Main Functions
void MapInit() {
	hasSpawnedBefore.resize(0);
	wasConnectedAtMapStart.resize(0);
	lastKnownSpawnLocation = Vector(0, 0, 0);
	mapAlreadyHadSurvival = false;
}

// Record all players who are connected at map start
void RecordConnectedPlayers() {
	wasConnectedAtMapStart.resize(0);
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null || !plr.IsConnected())
			continue;
		
		string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());
		wasConnectedAtMapStart.insertLast(steamId);
	}
}

// Check for players who are spectating with no body
void CheckPlayersWithoutBodies() {
	// Don't run if map already had survival support
	if (mapAlreadyHadSurvival)
		return;

	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null || !plr.IsConnected())
			continue;

		string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());

		// If player is alive, mark them as having spawned
		if (plr.IsAlive()) {
			if (hasSpawnedBefore.find(steamId) < 0) {
				hasSpawnedBefore.insertLast(steamId);
			}
			continue;
		}

		// Player is dead - get their observer
		Observer@ obs = plr.GetObserver();
		
		// Make sure they're actually observing before we do anything
		if (!obs.IsObserver())
			continue;
		
		// Check if they have a corpse
		if (obs.HasCorpse())
			continue;

		// Player is observing with NO corpse - determine what to do
		// TRUE late joiner = connected AFTER map started AND never spawned
		bool isTrueLateJoiner = (wasConnectedAtMapStart.find(steamId) < 0) && (hasSpawnedBefore.find(steamId) < 0);
		
		if (isTrueLateJoiner && cvar_lateSpawn.GetInt() == 1) {
			// TRUE LATE JOINER: Spawn them ALIVE at spawn
			Vector spawnPoint = GetValidSpawnPoint(plr);
			if (spawnPoint != Vector(0, 0, 0)) {
				g_EntityFuncs.SetOrigin(plr, spawnPoint);
			}
			plr.Revive();
			hasSpawnedBefore.insertLast(steamId);
		} else if (hasSpawnedBefore.find(steamId) >= 0) {
			// GIBBED/VOID PLAYER: Create a corpse at spawn (only if they've spawned before)
			CreateCorpseAtSpawn(plr);
		}
		// else: Player was connected at start but hasn't spawned yet - let them spawn naturally
	}
}

// Get a valid spawn point location using IsSpawnPointValid
Vector GetValidSpawnPoint(CBasePlayer@ plr) {
	if (plr is null)
		return Vector(0, 0, 0);
	
	array<string> spawnClassnames = {
		"info_player_coop",
		"info_player_deathmatch",
		"info_player_start"
	};

	// Try each spawn type in priority order
	for (uint i = 0; i < spawnClassnames.length(); i++) {
		CBaseEntity@ pSpawn = null;
		
		// Find all spawns of this type and check if they're valid
		while ((@pSpawn = g_EntityFuncs.FindEntityByClassname(pSpawn, spawnClassnames[i])) !is null) {
			// Use the game's built-in validation to check if this spawn is active and usable
			if (g_PlayerFuncs.IsSpawnPointValid(pSpawn, plr)) {
				// Found a valid spawn point!
				return pSpawn.pev.origin;
			}
		}
	}

	return Vector(0, 0, 0);
}

// Periodic check to move all corpses when spawn changes
void MoveCorpsesToNewSpawn() {
	// Don't run if map already had survival support
	if (mapAlreadyHadSurvival)
		return;

	// Get current spawn location
	CBasePlayer@ anyPlayer = null;
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		@anyPlayer = g_PlayerFuncs.FindPlayerByIndex(i);
		if (anyPlayer !is null && anyPlayer.IsConnected())
			break;
	}
	
	if (anyPlayer is null)
		return;
	
	Vector currentSpawn = GetValidSpawnPoint(anyPlayer);
	
	if (currentSpawn == Vector(0, 0, 0))
		return;

	// Initialize last known spawn if this is first check
	if (lastKnownSpawnLocation.x == 0 && lastKnownSpawnLocation.y == 0 && lastKnownSpawnLocation.z == 0) {
		lastKnownSpawnLocation = currentSpawn;
		return;
	}

	// Check if spawn has moved significantly
	float spawnMovement = (currentSpawn - lastKnownSpawnLocation).Length();

	// If spawn hasn't moved, nothing to do
	if (spawnMovement < 100.0)
		return;

	// Spawn has moved! Move ALL corpses to new spawn	
	// Collect all deadplayer entities first
	array<CBaseEntity@> allCorpses;
	CBaseEntity@ pCorpse = null;
	while ((@pCorpse = g_EntityFuncs.FindEntityByClassname(pCorpse, "deadplayer")) !is null) {
		allCorpses.insertLast(pCorpse);
	}
	
	// Now move them all
	for (uint i = 0; i < allCorpses.length(); i++) {
		g_EntityFuncs.SetOrigin(allCorpses[i], currentSpawn);
		
		// Try to notify and move the player who owns this corpse
		int corpseOwnerIndex = int(allCorpses[i].pev.renderamt);
		CBasePlayer@ corpseOwner = g_PlayerFuncs.FindPlayerByIndex(corpseOwnerIndex);
	}
	
	// Update last known spawn location
	lastKnownSpawnLocation = currentSpawn;
}

// Create a corpse at spawn for gibbed/void players
void CreateCorpseAtSpawn(CBasePlayer@ plr) {
	// Don't run if map already had survival support
	if (mapAlreadyHadSurvival)
		return;
		
	if (plr is null)
		return;
	
	Observer@ obs = plr.GetObserver();
	if (obs is null)
		return;
	
	// Only do this if they're currently observing
	if (!obs.IsObserver())
		return;
	
	// Get their current observer position and angles BEFORE stopping
	Vector currentObsPos = plr.pev.origin;
	Vector currentAngles = plr.pev.angles;
	
	// Stop observer mode (false = don't respawn them)
	obs.StopObserver(false);
	
	// Start observer at their CURRENT position with body creation enabled
	// This creates a deadplayer entity at their current location
	obs.StartObserver(currentObsPos, currentAngles, true);
	
	// Get spawn point where we want to move the corpse
	Vector spawnPoint = GetValidSpawnPoint(plr);
	if (spawnPoint == Vector(0, 0, 0))
		return;
	
	// Wait a moment for the corpse to be created, then move it
	dictionary args;
	args['playerIndex'] = plr.entindex();
	args['spawnPoint'] = spawnPoint;
	g_Scheduler.SetTimeout("MoveNewlyCreatedCorpse", 0.1, @args);
	
	// Mark them as having spawned before
	string steamId = g_EngineFuncs.GetPlayerAuthId(plr.edict());
	if (hasSpawnedBefore.find(steamId) < 0) {
		hasSpawnedBefore.insertLast(steamId);
	}
}

// Move the newly created corpse to spawn point
void MoveNewlyCreatedCorpse(dictionary@ args) {
	// Don't run if map already had survival support
	if (mapAlreadyHadSurvival)
		return;
		
	int playerIndex = int(args['playerIndex']);
	Vector spawnPoint = Vector(args['spawnPoint']);
	
	CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(playerIndex);
	if (plr is null)
		return;
	
	// Find their newly created deadplayer entity
	CBaseEntity@ pCorpse = null;
	int playerEntIndex = plr.entindex();
	while ((@pCorpse = g_EntityFuncs.FindEntityByClassname(pCorpse, "deadplayer")) !is null) {
		if (int(pCorpse.pev.renderamt) == playerEntIndex) {
			// Found their corpse! Move it to spawn point
			g_EntityFuncs.SetOrigin(pCorpse, spawnPoint);
			break;
		}
	}
}
