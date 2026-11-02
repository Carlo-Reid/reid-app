-- Bank: pairing transfers clears the old pairs first (the database wants a WHERE on a DELETE)
DO $do$
DECLARE src text := pg_get_functiondef('public.bank_transfer_match()'::regprocedure);
BEGIN
  IF src LIKE '%DELETE FROM bank_transfer_links;%' THEN EXECUTE replace(src, 'DELETE FROM bank_transfer_links;', 'DELETE FROM bank_transfer_links WHERE true;'); END IF;
END $do$;
