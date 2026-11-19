-- 322_speed_2.sql  (Carlo, Nov 19, 2026: speed, round 2)
-- Nothing here changes what a page shows.
--   1. The database had never worked out its statistics for customers, visits, invoice lines, notes and
--      about 200 other tables (and jobs not since Oct 21), so it picked slow ways to find things
--      (the sales history read all 133,000 jobs to find 3,900 sold proposals). ANALYZE was run by hand
--      on Nov 19; this keeps it fresh: every night at 3:17 a.m. Ottawa (8:17 UTC).
--   2. "Is this customer in here twice?" (customer_dupe_hint, asked each time a customer's page opens)
--      read every phone number and address. Two indexes let it look them up.

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'analyze-nightly';
SELECT cron.schedule('analyze-nightly', '17 8 * * *', $$ANALYZE$$);

-- the same words customer_dupe_hint compares (public._norm_contact('phone', value), written out), so the index is used
CREATE INDEX IF NOT EXISTS customer_contacts_phone10c_idx ON public.customer_contacts
  USING btree ("right"(regexp_replace(coalesce(value, ''), '\D', '', 'g'), 10)) WHERE kind IN ('phone', 'mobile');
CREATE INDEX IF NOT EXISTS locations_dupe_key_idx ON public.locations
  USING btree ((upper(regexp_replace(street, '[^A-Za-z0-9]', '', 'g')) || '|' || coalesce(upper(replace(postal_code, ' ', '')), upper(city)))) WHERE active;
