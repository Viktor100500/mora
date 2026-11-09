-- The Telegram function's settings may live in Supabase Vault instead of
-- function secrets: secrets named mora_telegram_<setting> (bot_token,
-- phone_token, webhook_secret, allowed_users, miniapp_url, miniapp_link,
-- widget_api). Only the service role, which the function holds, can read them.
-- Function secrets with the same meaning (TELEGRAM_BOT_TOKEN, ...) take precedence.
begin;
create function public.mora_telegram_settings() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(substr(name, 15), decrypted_secret), '{}'::jsonb)
  from vault.decrypted_secrets where name like 'mora\_telegram\_%'
$$;
revoke all on function public.mora_telegram_settings() from public, anon, authenticated;
grant execute on function public.mora_telegram_settings() to service_role;
commit;
notify pgrst, 'reload schema';
