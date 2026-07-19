
-- ENUMS
CREATE TYPE public.sale_status AS ENUM ('pending','approved','rejected');
CREATE TYPE public.payout_type AS ENUM ('ADVANCE','FINAL_ADJUSTMENT','WITHDRAWAL','REVERSAL');
CREATE TYPE public.payout_status AS ENUM ('success','failed','cancelled','rejected');
CREATE TYPE public.withdrawal_status AS ENUM ('pending','success','failed');

-- USERS (app-level, not auth.users — assignment uses simple user distinguishing)
CREATE TABLE public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  email text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- SALES
CREATE TABLE public.sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  brand text NOT NULL,
  earning numeric(12,2) NOT NULL CHECK (earning > 0),
  status public.sale_status NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(),
  reconciled_at timestamptz
);
CREATE INDEX idx_sales_status ON public.sales(status);
CREATE INDEX idx_sales_user ON public.sales(user_id);

-- PAYOUTS ledger (append-only; never UPDATE amount)
CREATE TABLE public.payouts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  sale_id uuid REFERENCES public.sales(id) ON DELETE CASCADE,
  type public.payout_type NOT NULL,
  amount numeric(12,2) NOT NULL,
  status public.payout_status NOT NULL,
  ref_payout_id uuid REFERENCES public.payouts(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_payouts_user ON public.payouts(user_id);
CREATE INDEX idx_payouts_sale ON public.payouts(sale_id);
CREATE INDEX idx_payouts_user_created ON public.payouts(user_id, created_at);

-- Physically prevent double successful ADVANCE per sale
CREATE UNIQUE INDEX uniq_advance_per_sale
  ON public.payouts(sale_id)
  WHERE type = 'ADVANCE' AND status = 'success';

-- WITHDRAWALS
CREATE TABLE public.withdrawals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  status public.withdrawal_status NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_withdrawals_user ON public.withdrawals(user_id);
CREATE INDEX idx_withdrawals_user_created ON public.withdrawals(user_id, created_at);

-- GRANTS: keep tables locked to anon/authenticated at the Data API layer.
-- All reads/writes go through server functions using service_role (bypasses RLS).
GRANT ALL ON public.users TO service_role;
GRANT ALL ON public.sales TO service_role;
GRANT ALL ON public.payouts TO service_role;
GRANT ALL ON public.withdrawals TO service_role;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawals ENABLE ROW LEVEL SECURITY;

-- No policies for anon/authenticated => Data API returns nothing.
-- Service role bypasses RLS, so server functions have full access.

-- =========================================================
-- ATOMIC BUSINESS-LOGIC FUNCTIONS (server-side correctness)
-- These are SECURITY DEFINER so server functions can call them via RPC
-- and get row-locking + transactionality inside a single DB call.
-- =========================================================

-- Run advance payout job: 10% of every pending sale that hasn't gotten one.
-- Idempotent by construction (unique index) + explicit anti-join.
CREATE OR REPLACE FUNCTION public.run_advance_payout_job()
RETURNS TABLE(processed_count int, total_advance numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int := 0;
  v_total numeric := 0;
BEGIN
  WITH eligible AS (
    SELECT s.id, s.user_id, s.earning
    FROM public.sales s
    WHERE s.status = 'pending'
      AND NOT EXISTS (
        SELECT 1 FROM public.payouts p
        WHERE p.sale_id = s.id
          AND p.type = 'ADVANCE'
          AND p.status = 'success'
      )
    FOR UPDATE OF s
  ),
  inserted AS (
    INSERT INTO public.payouts (user_id, sale_id, type, amount, status)
    SELECT user_id, id, 'ADVANCE', ROUND(earning * 0.10, 2), 'success'
    FROM eligible
    RETURNING amount
  )
  SELECT COUNT(*)::int, COALESCE(SUM(amount),0) INTO v_count, v_total FROM inserted;

  RETURN QUERY SELECT v_count, v_total;
END;
$$;

-- Reconcile a sale atomically. Rejects if already reconciled.
CREATE OR REPLACE FUNCTION public.reconcile_sale(p_sale_id uuid, p_new_status public.sale_status)
RETURNS TABLE(sale_id uuid, final_adjustment numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sale public.sales%ROWTYPE;
  v_advance numeric := 0;
  v_final numeric;
BEGIN
  IF p_new_status NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  -- Lock the sale row to prevent concurrent reconciles
  SELECT * INTO v_sale FROM public.sales WHERE id = p_sale_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_sale.status <> 'pending' THEN
    RAISE EXCEPTION 'already_reconciled' USING ERRCODE = '23505';
  END IF;

  SELECT COALESCE(SUM(amount),0) INTO v_advance
  FROM public.payouts
  WHERE sale_id = p_sale_id AND type = 'ADVANCE' AND status = 'success';

  -- Unified formula: (approved ? earning : 0) - advancePaid
  v_final := (CASE WHEN p_new_status = 'approved' THEN v_sale.earning ELSE 0 END) - v_advance;

  INSERT INTO public.payouts (user_id, sale_id, type, amount, status)
  VALUES (v_sale.user_id, p_sale_id, 'FINAL_ADJUSTMENT', v_final, 'success');

  UPDATE public.sales
  SET status = p_new_status, reconciled_at = now()
  WHERE id = p_sale_id;

  RETURN QUERY SELECT p_sale_id, v_final;
END;
$$;

-- Compute withdrawable balance from ledger (sum of successful entries)
CREATE OR REPLACE FUNCTION public.get_balance(p_user_id uuid)
RETURNS numeric
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(amount),0)
  FROM public.payouts
  WHERE user_id = p_user_id AND status = 'success';
$$;

-- Request a withdrawal atomically with balance + 24h check
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_user_id uuid, p_amount numeric)
RETURNS TABLE(withdrawal_id uuid, payout_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_balance numeric;
  v_last timestamptz;
  v_wid uuid;
  v_pid uuid;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = '22023';
  END IF;

  -- Lock all rows for this user to serialize concurrent withdrawals
  PERFORM 1 FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- 24h cooldown: last non-failed withdrawal
  SELECT MAX(created_at) INTO v_last
  FROM public.withdrawals
  WHERE user_id = p_user_id AND status <> 'failed';

  IF v_last IS NOT NULL AND v_last > (now() - interval '24 hours') THEN
    RAISE EXCEPTION 'cooldown_active:%', EXTRACT(EPOCH FROM (v_last + interval '24 hours' - now()))::bigint
      USING ERRCODE = 'P0001';
  END IF;

  SELECT public.get_balance(p_user_id) INTO v_balance;
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'insufficient_balance:%', v_balance USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.withdrawals (user_id, amount, status)
  VALUES (p_user_id, p_amount, 'success')
  RETURNING id INTO v_wid;

  INSERT INTO public.payouts (user_id, sale_id, type, amount, status)
  VALUES (p_user_id, NULL, 'WITHDRAWAL', -p_amount, 'success')
  RETURNING id INTO v_pid;

  RETURN QUERY SELECT v_wid, v_pid;
END;
$$;

-- Simulate a payout-gateway failure: mark withdrawal failed + credit reversal
CREATE OR REPLACE FUNCTION public.fail_withdrawal(p_withdrawal_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_w public.withdrawals%ROWTYPE;
  v_orig_payout uuid;
  v_reversal uuid;
BEGIN
  SELECT * INTO v_w FROM public.withdrawals WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'withdrawal_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_w.status = 'failed' THEN
    RAISE EXCEPTION 'already_failed' USING ERRCODE = '23505';
  END IF;

  -- Find the original WITHDRAWAL ledger row that matches (same user, same amount, closest by time)
  SELECT id INTO v_orig_payout
  FROM public.payouts
  WHERE user_id = v_w.user_id
    AND type = 'WITHDRAWAL'
    AND status = 'success'
    AND amount = -v_w.amount
    AND created_at >= v_w.created_at - interval '1 second'
  ORDER BY created_at ASC
  LIMIT 1;

  UPDATE public.withdrawals SET status = 'failed' WHERE id = p_withdrawal_id;

  INSERT INTO public.payouts (user_id, sale_id, type, amount, status, ref_payout_id)
  VALUES (v_w.user_id, NULL, 'REVERSAL', v_w.amount, 'success', v_orig_payout)
  RETURNING id INTO v_reversal;

  RETURN v_reversal;
END;
$$;
