-- ============================================================================
-- LMTTW — fix for "everyone is #1 on their own leaderboard" / podium not
-- showing on player screens / players can't see quiz reports.
--
-- ROOT CAUSE
-- ----------
-- The app's front-end (index.html) pulls the WHOLE `scores` table and the
-- WHOLE `live_players` table for a session into the browser, then computes
-- leaderboards/podiums/reports locally from that data (see getLeaderboard(),
-- getQuizLeaderboard(), showPodiumAsPlayer() in index.html). That only works
-- if every signed-in player is *allowed* to read every row, not just their
-- own. Right now your Row Level Security policies on `scores` and
-- `live_players` only let a user SELECT their own row, so each player's
-- browser only ever receives one row — their own — which is why each one
-- shows up as the lone #1 on their own screen, and why the live podium and
-- per-quiz/solo reports look empty or wrong on a player's device even
-- though the host (who apparently has broader read access) sees it fine.
--
-- THE FIX
-- -------
-- Leaderboards and podiums are meant to be public-within-the-app data, so
-- the safe fix is: let any signed-in user SELECT all rows of `scores` and
-- `live_players`, but keep INSERT/UPDATE locked down to each player's own
-- row exactly as before. This does not touch `profiles`, `quizzes`, or
-- `live_sessions` — leave those exactly as they are unless you hit a
-- similar symptom there too.
--
-- Run this in the Supabase SQL editor for your project. It's safe to
-- re-run; it only ever drops/recreates the SELECT policies on these two
-- tables and does not touch INSERT/UPDATE/DELETE policies.
-- ============================================================================

-- 1) See what SELECT policies currently exist on these tables, for your own
--    reference before/after running the fix below.
select schemaname, tablename, policyname, cmd, qual
from pg_policies
where tablename in ('scores','live_players')
order by tablename, cmd;

-- 2) Drop every existing SELECT policy on scores + live_players (whatever
--    they happen to be named) and replace with a single permissive,
--    non-recursive "any authenticated user can read" policy. Non-recursive
--    is important — this is what avoids the infinite-recursion error you
--    hit before, because it does NOT query `profiles` (or any other
--    RLS-protected table) inside the policy.
do $$
declare pol record;
begin
  for pol in
    select policyname from pg_policies
    where tablename = 'scores' and cmd = 'SELECT'
  loop
    execute format('drop policy %I on public.scores', pol.policyname);
  end loop;

  for pol in
    select policyname from pg_policies
    where tablename = 'live_players' and cmd = 'SELECT'
  loop
    execute format('drop policy %I on public.live_players', pol.policyname);
  end loop;
end $$;

create policy "scores_select_all_authenticated"
  on public.scores
  for select
  to authenticated
  using (true);

create policy "live_players_select_all_authenticated"
  on public.live_players
  for select
  to authenticated
  using (true);

-- 3) Make sure Realtime is actually broadcasting changes on these tables —
--    this is what pushes the podium update to every player's screen the
--    instant the host reveals answers. Wrapped so it's a no-op (not an
--    error that aborts the whole script) if a table's already added.
do $$
begin
  alter publication supabase_realtime add table public.live_sessions;
exception when duplicate_object then
  null; -- already added, nothing to do
end $$;

do $$
begin
  alter publication supabase_realtime add table public.live_players;
exception when duplicate_object then
  null; -- already added, nothing to do
end $$;

-- ============================================================================
-- WHAT THIS DELIBERATELY DOES NOT TOUCH
-- ============================================================================
-- - INSERT/UPDATE/DELETE policies on scores/live_players (players should
--   still only be able to write their own row — leave that as-is).
-- - profiles, quizzes, live_sessions RLS — these already appear to be
--   readable correctly (player names and quiz lists show up fine for
--   everyone), so there's no reason to touch them.
-- ============================================================================
