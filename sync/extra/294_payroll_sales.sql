-- Payroll: a sales person's leads, what they sold, their commission rates (George, Nov 14: "I want to know how much they sold for what
-- they got paid… any lead that was given to them… lost to another provider or customer changed mind… or we won it and it was installed
-- and they were paid commission… a section in their profiles for how much commission for install or another product"). Owners only.

-- why each proposal was not sold (the leads list on a person's payroll page)
CREATE OR REPLACE FUNCTION public.payroll_est_outcomes(p_ids bigint[]) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  SELECT CASE WHEN public._src_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'status', e.status, 'reason', e.lost_reason, 'note', e.lost_note,
      'cancelled', e.cancelled_at IS NOT NULL))
    FROM estimates e WHERE e.id = ANY (p_ids)), '[]'::jsonb) ELSE '[]'::jsonb END $f$;
REVOKE EXECUTE ON FUNCTION public.payroll_est_outcomes(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_est_outcomes(bigint[]) TO authenticated;

-- a new kind of product with its own commission (the person's rate for it is set with comm_rate_set)
CREATE OR REPLACE FUNCTION public.comm_group_add(p_name text, p_keywords text) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v bigint;
BEGIN
  IF NOT public._can_installs() THEN RAISE EXCEPTION 'You don''t have permission to set commission rates'; END IF;
  IF nullif(btrim(coalesce(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Type the name of the product'; END IF;
  PERFORM 'x' ~* coalesce(nullif(btrim(p_keywords), ''), 'x');   -- a bad pattern stops here with an error
  SELECT id INTO v FROM commission_groups WHERE lower(name) = lower(btrim(p_name));
  IF v IS NOT NULL THEN RETURN v; END IF;
  -- before Other, so Other stays last
  INSERT INTO commission_groups (name, sort_order, keywords)
  VALUES (btrim(p_name), coalesce((SELECT max(sort_order) FROM commission_groups WHERE name <> 'Other'), 0) + 1, nullif(btrim(p_keywords), ''))
  RETURNING id INTO v;
  UPDATE commission_groups SET sort_order = greatest(sort_order, (SELECT max(sort_order) FROM commission_groups WHERE name <> 'Other') + 10) WHERE name = 'Other';
  RETURN v;
END $f$;
REVOKE EXECUTE ON FUNCTION public.comm_group_add(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.comm_group_add(text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';
