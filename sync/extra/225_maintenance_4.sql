-- Book a call → Maintenance: a 4th button, "Maintenance 4" (four systems), next to Maintenance 1, 2 and 3. Made here (not in ServiceTitan).
-- Safe to run more than once.
DO $$
DECLARE v_unit bigint; v_dur int;
BEGIN
  IF EXISTS (SELECT 1 FROM job_types WHERE name ~* '^maintenance 4$') THEN RETURN; END IF;
  SELECT coalesce(t.business_unit_id, (SELECT j.business_unit_id FROM jobs j WHERE j.job_type_id = t.id AND j.business_unit_id IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC LIMIT 1)),
         coalesce(t.default_duration_minutes, 105) + 20
    INTO v_unit, v_dur FROM job_types t WHERE t.name ~* '^maintenance 3$' LIMIT 1;
  IF v_unit IS NULL THEN SELECT id INTO v_unit FROM business_units WHERE name ~* 'maint' ORDER BY id LIMIT 1; END IF;
  BEGIN
    INSERT INTO job_types (name, job_class, business_unit_id, default_duration_minutes, active) VALUES ('Maintenance 4', 'maintenance', v_unit, coalesce(v_dur, 125), true);
  EXCEPTION WHEN not_null_violation THEN   -- no id of its own: give it one that ServiceTitan's never use
    INSERT INTO job_types (id, name, job_class, business_unit_id, default_duration_minutes, active)
    VALUES (least(-1, (SELECT min(id) - 1 FROM job_types)), 'Maintenance 4', 'maintenance', v_unit, coalesce(v_dur, 125), true);
  END;
END $$;
NOTIFY pgrst, 'reload schema';
