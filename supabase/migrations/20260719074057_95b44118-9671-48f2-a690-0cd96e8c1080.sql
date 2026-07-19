
REVOKE EXECUTE ON FUNCTION public.run_advance_payout_job() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reconcile_sale(uuid, public.sale_status) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_balance(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.request_withdrawal(uuid, numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fail_withdrawal(uuid) FROM PUBLIC, anon, authenticated;
