CREATE OR REPLACE FUNCTION public.reset_demo_data()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_john uuid := '11111111-1111-1111-1111-111111111111';
  v_priya uuid := '22222222-2222-2222-2222-222222222222';
BEGIN
  -- Wipe ledger, withdrawals, sales for both demo users (order matters: payouts reference sales).
  DELETE FROM public.payouts WHERE user_id IN (v_john, v_priya);
  DELETE FROM public.withdrawals WHERE user_id IN (v_john, v_priya);
  DELETE FROM public.sales WHERE user_id IN (v_john, v_priya);

  -- Re-seed John: 3 pending brand_1 sales at 40 each.
  INSERT INTO public.sales (user_id, brand, earning, status)
  VALUES
    (v_john, 'brand_1', 40, 'pending'),
    (v_john, 'brand_1', 40, 'pending'),
    (v_john, 'brand_1', 40, 'pending');

  -- Re-seed Priya: 3 pending sales to demo reconciliation + withdrawal flows.
  INSERT INTO public.sales (user_id, brand, earning, status)
  VALUES
    (v_priya, 'brand_2', 500, 'pending'),
    (v_priya, 'brand_3', 200, 'pending'),
    (v_priya, 'brand_2', 800, 'pending');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.reset_demo_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reset_demo_data() TO service_role;