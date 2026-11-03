DO $$ BEGIN RAISE EXCEPTION 'P18 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 3061, 170), chr(10), '~'), chr(13), ''); END $$;
