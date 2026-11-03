DO $$ BEGIN RAISE EXCEPTION 'P22 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 3741, 170), chr(10), '~'), chr(13), ''); END $$;
