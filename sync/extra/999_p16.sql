DO $$ BEGIN RAISE EXCEPTION 'P16 %', replace(replace(substr(pg_get_functiondef('public.inv_take_payment'::regproc), 2721, 170), chr(10), '~'), chr(13), ''); END $$;
