# La Guerre des Couronnes — Aldarène

Application web multijoueur gratuite pour GitHub Pages et Supabase.

## Fonctionnement

- L’animateur prépare les maisons, crée une salle et conserve le contrôle des lois, des levées et de la fin de partie.
- Chaque joueur reçoit un lien personnel et peut renforcer, rappeler des troupes, attaquer et effectuer un larcin avec sa propre maison.
- La partie est enregistrée dans Supabase et actualisée automatiquement sur tous les appareils.
- Les actions concurrentes utilisent un numéro de version afin d’éviter qu’une modification en écrase une autre.

## Déploiement

1. Exécuter `supabase/migrations/202609160001_aldarene_multiplayer.sql` dans le projet Supabase.
2. Copier l’URL du projet et sa clé publique/publishable dans `supabase-config.js`.
3. Publier les fichiers de ce dossier avec GitHub Pages.

La clé `service_role` ne doit jamais être placée dans l’application. Les tables sont protégées par RLS et les quatre fonctions RPC publiques contrôlent les jetons de salle.
