-- Notes on a sale, shown on the Sales page (Customer paid column).
-- One-time copy (Oct 27, 2026): the pinned location notes that say "Costco payment" (a back-up record of Costco paying when
-- it was missed on the invoice), each put on that customer's Costco sale(s). Safe to run again: copied once only.
CREATE TABLE IF NOT EXISTS public.sale_notes (
  id bigserial PRIMARY KEY, est_id bigint NOT NULL, job_id bigint, source_note_id bigint, body text NOT NULL,
  noted_at timestamptz, kind text NOT NULL DEFAULT 'costco payment', created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (est_id, source_note_id));
ALTER TABLE public.sale_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_read ON public.sale_notes;
CREATE POLICY staff_read ON public.sale_notes FOR SELECT TO authenticated USING ((SELECT public.current_staff_role()) IS NOT NULL);
REVOKE ALL ON public.sale_notes FROM anon; GRANT SELECT ON public.sale_notes TO authenticated;
INSERT INTO public.sale_notes (est_id, job_id, source_note_id, noted_at, body) VALUES
  (108011444, 108001364, 720753, '2026-07-21T21:55:50+00:00', '***Costco lead# 1699665*** Costco Payment received Aug 19'),
  (104220140, 103622900, 787930, '2026-10-07T15:28:36+00:00', 'Costco payment received Aug 4'),
  (104798200, 104578593, 787905, '2026-10-07T15:29:09+00:00', 'Costco Payment received Aug 6'),
  (105085153, 104578593, 787905, '2026-10-07T15:29:09+00:00', 'Costco Payment received Aug 6'),
  (106311051, 106310047, 787983, '2026-10-07T15:29:53+00:00', 'Costco payment received Aug 10'),
  (106307524, 106310047, 787983, '2026-10-07T15:29:53+00:00', 'Costco payment received Aug 10'),
  (106845661, 106697488, 787922, '2026-10-07T15:30:42+00:00', 'Costco payment received aug 10'),
  (106865265, 106699671, 788038, '2026-10-07T15:31:28+00:00', 'Costco payment received aug 10'),
  (106813912, 106699639, 788061, '2026-10-07T15:31:58+00:00', 'costco payment received aug 17'),
  (106818664, 106699639, 788061, '2026-10-07T15:31:58+00:00', 'costco payment received aug 17'),
  (106813920, 106699639, 788061, '2026-10-07T15:31:58+00:00', 'costco payment received aug 17'),
  (104796206, 104690971, 788114, '2026-10-07T15:33:24+00:00', 'Costco payment received 9,040.24'),
  (107771911, 107732711, 788156, '2026-10-07T15:35:50+00:00', 'Costco payment received aug 31 6,929.27')
ON CONFLICT (est_id, source_note_id) DO NOTHING;
NOTIFY pgrst, 'reload schema';
