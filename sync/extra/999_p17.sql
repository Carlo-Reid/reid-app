DO $$ BEGIN RAISE EXCEPTION 'P17 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 2891, 170), chr(10), '~'), chr(13), ''); END $$;
