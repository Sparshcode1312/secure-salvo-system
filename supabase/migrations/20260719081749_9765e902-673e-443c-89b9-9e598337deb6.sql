CREATE OR REPLACE FUNCTION public.reconcile_sale(p_sale_id uuid, p_new_status sale_status)
 RETURNS TABLE(sale_id uuid, final_adjustment numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sale public.sales%ROWTYPE;
  v_advance numeric := 0;
  v_final numeric;
BEGIN
  IF p_new_status NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_sale FROM public.sales s WHERE s.id = p_sale_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'sale_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_sale.status <> 'pending' THEN
    RAISE EXCEPTION 'already_reconciled' USING ERRCODE = '23505';
  END IF;

  SELECT COALESCE(SUM(p.amount),0) INTO v_advance
  FROM public.payouts p
  WHERE p.sale_id = p_sale_id AND p.type = 'ADVANCE' AND p.status = 'success';

  v_final := (CASE WHEN p_new_status = 'approved' THEN v_sale.earning ELSE 0 END) - v_advance;

  INSERT INTO public.payouts (user_id, sale_id, type, amount, status)
  VALUES (v_sale.user_id, p_sale_id, 'FINAL_ADJUSTMENT', v_final, 'success');

  UPDATE public.sales s
  SET status = p_new_status, reconciled_at = now()
  WHERE s.id = p_sale_id;

  RETURN QUERY SELECT p_sale_id AS sale_id, v_final AS final_adjustment;
END;
$function$;