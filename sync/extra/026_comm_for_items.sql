-- Commission on a proposal (owners): each item's type of work and every sales person's % on it, in one call.
-- Safe to run more than once.
CREATE OR REPLACE FUNCTION public.comm_for_items(p_ids bigint[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $f$
  SELECT CASE WHEN NOT public._can_installs() THEN NULL ELSE coalesce(jsonb_agg(jsonb_build_object(
    'item_id', x.id,
    'group', (SELECT name FROM commission_groups WHERE id = public._comm_group(x.id)),
    'rates', (SELECT coalesce(jsonb_object_agg(e.id, public._comm_pct(e.id, x.id)), '{}') FROM employees e
              WHERE e.id IN (SELECT employee_id FROM commission_rates UNION SELECT employee_id FROM commission_group_rates)))), '[]') END
  FROM (SELECT DISTINCT unnest(p_ids) AS id) x
$f$;
REVOKE EXECUTE ON FUNCTION public.comm_for_items(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.comm_for_items(bigint[]) TO authenticated;
NOTIFY pgrst, 'reload schema';
