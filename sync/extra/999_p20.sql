DO $$ BEGIN RAISE EXCEPTION 'P20 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 3401, 170), chr(10), '~'), chr(13), ''); END $$;
