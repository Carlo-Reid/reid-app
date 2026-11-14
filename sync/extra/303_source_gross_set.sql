-- George, Nov 14, 2026: "are you also adding the gross pay for the period of the source". The gross payroll (and the number of employees)
-- printed on the payment confirmation can be typed on a source payment that is already saved, and on the PDFs that need checking.
CREATE OR REPLACE FUNCTION public.source_gross_set(p_id bigint, p_gross numeric, p_employees integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE r source_remits;
BEGIN
  IF NOT public._src_owner() THEN RAISE EXCEPTION 'Only owners can change source payments'; END IF;
  IF p_gross IS NOT NULL AND p_gross < 0 THEN RAISE EXCEPTION 'The gross payroll can not be below zero'; END IF;
  UPDATE source_remits SET gross = p_gross, employees = p_employees WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'That source payment was not found'; END IF;
  RETURN public._src_json(r);
END $f$;
REVOKE ALL ON FUNCTION public.source_gross_set(bigint, numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.source_gross_set(bigint, numeric, integer) TO authenticated;
