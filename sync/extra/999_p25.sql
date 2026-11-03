DO $$ BEGIN RAISE EXCEPTION 'P25 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 4251, 170), chr(10), '~'), chr(13), ''); END $$;
