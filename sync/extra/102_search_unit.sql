-- Customer search: a Unit box beside Address. The app sends the unit as a word "u:<unit>" with the address words;
-- it has to match the location's unit exactly (spaces, dashes and "#" don't matter), the other words match as before.
SELECT public._patch_fn('search_customers',
  'AND concat_ws('' '', l.street, l.unit, l.city, l.postal_code, replace(coalesce(l.postal_code, ''''), '' '', '''')) ILIKE ALL (a.pats)),',
  'AND concat_ws('' '', l.street, l.unit, l.city, l.postal_code, replace(coalesce(l.postal_code, ''''), '' '', '''')) ILIKE ALL (coalesce((SELECT array_agg(x) FROM unnest(a.pats) x WHERE x NOT LIKE ''\%u:%''), ARRAY[''%'']))
      AND NOT EXISTS (SELECT 1 FROM unnest(a.pats) x WHERE x LIKE ''\%u:%''
                      AND regexp_replace(lower(coalesce(l.unit, '''')), ''[^a-z0-9]'', '''', ''g'') <> regexp_replace(substr(x, 4, length(x) - 4), ''[^a-z0-9]'', '''', ''g''))),');
NOTIFY pgrst, 'reload schema';
