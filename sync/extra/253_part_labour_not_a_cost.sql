-- Labour hours on a Part or Material are not a job cost any more (Carlo, Nov 10: "yes stop counting them for jobs, just use their
-- profit amount on the jobs, but have the labour we add on the part just show with the part mark up as one").
-- The hours only raise the part's sell price (252). On a job, a part's profit is its sell price less what the part cost us: one number.
-- So the costing of invoices (inv_costing) and of estimates / the item's own profit box (est_costing) no longer turns a part's or a
-- material's hours into labour cost. Equipment and Security keep theirs; so do the parts inside a kit (a kit's labour is the kit's).
-- In-place patches, each only once. Safe to run more than once.
DO $do$
DECLARE r record; d text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('inv_costing', 'coalesce(pi.labour_hours, pi.est_labour_hours, 0)',
                    '(CASE WHEN pi.item_type IN (''service'', ''material'') THEN 0 ELSE coalesce(pi.labour_hours, pi.est_labour_hours, 0) END)'),
    ('est_costing', '''hours'', i.est_labour_hours, ''price'', i.unit_price, ''lab'', public._item_labour(i.id),',
                    '''hours'', CASE WHEN i.item_type IN (''service'', ''material'') THEN NULL ELSE i.est_labour_hours END, ''price'', i.unit_price, ''lab'', CASE WHEN i.item_type IN (''service'', ''material'') AND coalesce(public._item_labour(i.id) ->> ''from'', ''own'') = ''own'' THEN NULL ELSE public._item_labour(i.id) END,')
  ) v(fn, a, b) LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace WHERE ns.nspname = 'public' AND p.proname = r.fn;
    IF d IS NULL THEN RAISE NOTICE '%: not found', r.fn; CONTINUE; END IF;
    IF position(r.b in d) > 0 THEN CONTINUE; END IF;
    IF position(r.a in d) = 0 THEN RAISE NOTICE '%: the words to change were not found', r.fn; CONTINUE; END IF;
    EXECUTE replace(d, r.a, r.b);
  END LOOP;
END $do$;
