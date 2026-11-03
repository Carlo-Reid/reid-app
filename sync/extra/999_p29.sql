DO $$ BEGIN RAISE EXCEPTION 'P29 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 4931, 170), chr(10), '~'), chr(13), ''); END $$;
