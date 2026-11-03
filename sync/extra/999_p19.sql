DO $$ BEGIN RAISE EXCEPTION 'P19 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 3231, 170), chr(10), '~'), chr(13), ''); END $$;
