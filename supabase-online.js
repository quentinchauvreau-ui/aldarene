(function () {
  "use strict";

  const encoder = new TextEncoder();
  let client = null;

  function configured() {
    return /^https:\/\/.+\.supabase\.co$/.test(window.ALD_SUPABASE_URL || "") &&
      !String(window.ALD_SUPABASE_KEY || "").startsWith("__");
  }

  function init() {
    if (!configured()) throw new Error("La connexion Supabase n'est pas encore configurée.");
    if (!window.supabase?.createClient) throw new Error("La bibliothèque Supabase n'a pas pu être chargée.");
    client = window.supabase.createClient(window.ALD_SUPABASE_URL, window.ALD_SUPABASE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
    });
    return client;
  }

  function bytesToHex(bytes) {
    return Array.from(bytes, value => value.toString(16).padStart(2, "0")).join("");
  }

  function token() {
    const bytes = new Uint8Array(24);
    crypto.getRandomValues(bytes);
    return bytesToHex(bytes);
  }

  function storageKey(kind, room, playerId) {
    return `aldarene:supabase:${kind}:${room || "new"}${playerId ? `:${playerId}` : ""}`;
  }

  function remember(kind, room, value, playerId) {
    try { localStorage.setItem(storageKey(kind, room, playerId), value); } catch (error) {}
  }

  function recall(kind, room, playerId) {
    try { return localStorage.getItem(storageKey(kind, room, playerId)) || ""; } catch (error) { return ""; }
  }

  function createInvites(players) {
    return Object.fromEntries(players.map(player => [player.id, token()]));
  }

  async function rpc(name, args) {
    if (!client) init();
    const { data, error } = await client.rpc(name, args);
    if (error) throw new Error(error.message || "Erreur Supabase.");
    return data;
  }

  async function createGame(state, hallOfFame) {
    const hostToken = token();
    const invites = createInvites(state.players || []);
    const result = await rpc("aldarene_create_game", {
      p_state: state,
      p_hall_of_fame: hallOfFame || [],
      p_host_token: hostToken,
      p_player_tokens: invites
    });
    const room = String(result.room_code || "").toUpperCase();
    remember("host", room, hostToken);
    remember("invites", room, JSON.stringify(invites));
    return { ...result, room_code: room, hostToken, invites };
  }

  function hostCredentials(room) {
    let invites = {};
    try { invites = JSON.parse(recall("invites", room) || "{}"); } catch (error) {}
    return { token: recall("host", room), invites };
  }

  function playerToken(room, playerId, incoming) {
    const value = incoming || recall("player", room, playerId);
    if (incoming && room && playerId) remember("player", room, incoming, playerId);
    return value;
  }

  async function snapshot(room, accessToken) {
    return rpc("aldarene_game_snapshot", { p_room_code: room, p_access_token: accessToken });
  }

  async function replaceGame(room, accessToken, expectedVersion, state, hallOfFame, invites) {
    return rpc("aldarene_host_replace_game", {
      p_room_code: room,
      p_host_token: accessToken,
      p_expected_version: expectedVersion,
      p_state: state,
      p_hall_of_fame: hallOfFame || [],
      p_player_tokens: invites || {}
    });
  }

  async function act(room, accessToken, expectedVersion, action) {
    return rpc("aldarene_perform_action", {
      p_room_code: room,
      p_player_token: accessToken,
      p_expected_version: expectedVersion,
      p_action: action
    });
  }

  window.AldareneCloud = {
    configured, init, token, createInvites, createGame, hostCredentials,
    playerToken, snapshot, replaceGame, act, remember
  };
})();
