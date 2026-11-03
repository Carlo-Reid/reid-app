DO $$ BEGIN RAISE EXCEPTION 'P00 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 1, 170), chr(10), '~'), chr(13), ''); END $$;
