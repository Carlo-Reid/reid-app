-- Default sales commission % (Pricing control page): used on the item page's job costing when a sales person has no rate of
-- their own. Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS commission_default_pct numeric(5,2);

CREATE OR REPLACE FUNCTION public.pricing_control_set(p_labour numeric, p_margin numeric, p_commission numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change pricing'; END IF;
  IF p_labour IS NOT NULL AND (p_labour <= 0 OR p_labour > 1000) THEN RAISE EXCEPTION 'Type the labour cost per hour, e.g. 55'; END IF;
  IF p_margin IS NULL OR p_margin <= 0 OR p_margin >= 95 THEN RAISE EXCEPTION 'The margin goal has to be between 1 and 94%%'; END IF;
  IF p_commission IS NOT NULL AND (p_commission < 0 OR p_commission >= 50) THEN RAISE EXCEPTION 'The commission has to be between 0 and 49%%'; END IF;
  UPDATE company_settings SET labour_cost_per_hour = p_labour, margin_goal_pct = p_margin, commission_default_pct = p_commission;
END $f$;

REVOKE EXECUTE ON FUNCTION public.pricing_control_set(numeric, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pricing_control_set(numeric, numeric, numeric) TO authenticated;
NOTIFY pgrst, 'reload schema';
