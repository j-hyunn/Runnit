-- =============================================================================
-- Runnit :: 14. 트리거 전용 함수의 RPC 직접 호출 차단
-- -----------------------------------------------------------------------------
-- Supabase security advisor 발견: SECURITY DEFINER 로 선언된 트리거 함수들이
-- PostgREST 를 통해 /rest/v1/rpc/<함수명> 으로 anon/authenticated 가 직접 호출
--가능한 상태였다. 트리거 컨텍스트 밖에서 실행하면 Postgres 가 에러를 내긴
-- 하지만("trigger functions can only be called as triggers"), 불필요한 공격
-- 표면이므로 EXECUTE 권한을 회수한다.
--
-- 함수 생성 시 EXECUTE 는 기본적으로 PUBLIC 에도 부여된다. anon/authenticated
-- 에서만 회수하면 PUBLIC 경유로 여전히 실행 가능하므로 **PUBLIC 에서도 회수**해야
-- 한다(둘 다 한 파일에 담아, 처음에 PUBLIC 을 빠뜨렸던 실수를 반복하지 않는다).
-- =============================================================================

revoke execute on function public.handle_new_auth_user()                      from public, anon, authenticated;
revoke execute on function public.trg_challenge_participant_count()           from public, anon, authenticated;
revoke execute on function public.trg_participation_recompute()               from public, anon, authenticated;
revoke execute on function public.trg_runs_challenge_progress()               from public, anon, authenticated;
revoke execute on function public.trg_runs_evaluate_badges()                  from public, anon, authenticated;
revoke execute on function public.trg_runs_recompute_stats()                  from public, anon, authenticated;
revoke execute on function public.trg_runs_guard()                            from public, anon, authenticated;
revoke execute on function public.trg_profiles_guard()                        from public, anon, authenticated;
revoke execute on function public.trg_user_badges_guard()                     from public, anon, authenticated;
revoke execute on function public.trg_challenge_participations_guard()        from public, anon, authenticated;
revoke execute on function public.transition_challenge_statuses(timestamptz)  from anon, authenticated;
revoke execute on function public.refresh_all_leaderboards(timestamptz)       from anon, authenticated;
