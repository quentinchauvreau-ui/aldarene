-- Les joueurs utilisent uniquement le rôle anon via la clé publique du site.
-- Les fonctions privées ne doivent jamais être exécutables directement.
revoke execute on function private.aldarene_token_hash(text)
  from public, anon, authenticated;
revoke execute on function private.aldarene_html_escape(text)
  from public, anon, authenticated;

-- Réduit la surface exposée : aucun compte Supabase n'est requis pour jouer.
revoke execute on function public.aldarene_create_game(jsonb, jsonb, text, jsonb)
  from authenticated;
revoke execute on function public.aldarene_game_snapshot(text, text)
  from authenticated;
revoke execute on function public.aldarene_host_replace_game(text, text, bigint, jsonb, jsonb, jsonb)
  from authenticated;
revoke execute on function public.aldarene_perform_action(text, text, bigint, jsonb)
  from authenticated;
