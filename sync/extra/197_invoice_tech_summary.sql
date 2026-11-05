-- The tech's work summary that ServiceTitan keeps on each invoice ("what was found and done").
-- The sync fills it (once for every invoice already here, then with each new or changed one); the customer page shows it under Tech notes from calls.
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS tech_summary text;
NOTIFY pgrst, 'reload schema';
