-- the book-today deal is for Reid proposals only, never a partner's
SELECT public._patch_fn('install_hold_set', 'IF p_day IS NULL THEN
    UPDATE install_holds', 'IF p_day IS NOT NULL AND (e.partner_id IS NOT NULL OR EXISTS (SELECT 1 FROM jobs j WHERE j.id = e.job_id AND j.partner_id IS NOT NULL)) THEN
    RAISE EXCEPTION ''This deal is only for Reid proposals''; END IF;
  IF p_day IS NULL THEN
    UPDATE install_holds');
