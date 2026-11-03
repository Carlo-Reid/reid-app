DO $$ BEGIN RAISE EXCEPTION 'P23 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 3911, 170), chr(10), '~'), chr(13), ''); END $$;
