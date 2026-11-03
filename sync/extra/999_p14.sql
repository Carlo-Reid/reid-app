DO $$ BEGIN RAISE EXCEPTION 'P14 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 2381, 170), chr(10), '~'), chr(13), ''); END $$;
