-- Pricing control page (Settings): the company-wide numbers that go into prices and proposal costing.
-- labour_cost_per_hour: what an hour of a tech costs us (proposal costing, add-on kit labour). margin_goal_pct: the margin
-- proposals aim for (green/red on the costing card). Safe to run more than once.
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS labour_cost_per_hour numeric(10,2);
ALTER TABLE public.company_settings ADD COLUMN IF NOT EXISTS margin_goal_pct numeric(5,2) NOT NULL DEFAULT 40;

CREATE OR REPLACE FUNCTION public.pricing_control_set(p_labour numeric, p_margin numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $f$
BEGIN
  IF NOT (public.has_permission('pricebook.edit') OR coalesce(public._is_owner(), false)) THEN RAISE EXCEPTION 'You can''t change pricing'; END IF;
  IF p_labour IS NOT NULL AND (p_labour <= 0 OR p_labour > 1000) THEN RAISE EXCEPTION 'Type the labour cost per hour, e.g. 55'; END IF;
  IF p_margin IS NULL OR p_margin <= 0 OR p_margin >= 95 THEN RAISE EXCEPTION 'The margin goal has to be between 1 and 94%%'; END IF;
  UPDATE company_settings SET labour_cost_per_hour = p_labour, margin_goal_pct = p_margin WHERE id = (SELECT id FROM company_settings ORDER BY id LIMIT 1);
END $f$;

REVOKE EXECUTE ON FUNCTION public.pricing_control_set(numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pricing_control_set(numeric, numeric) TO authenticated;
NOTIFY pgrst, 'reload schema';
