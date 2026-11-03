-- Older partner remittances were recorded as e-Transfers or cheques ("ETransfer | Vista credit R5917"): partner matching keeps those
-- when they name the partner or a remittance #, and the e-Transfer / cheque matching leaves them to the partner.
DO $do$
DECLARE s1 text := pg_get_functiondef('public.bank_partner_match(bigint)'::regprocedure);
        s2 text := pg_get_functiondef('public.bank_pay_match(text, integer)'::regprocedure);
BEGIN
  IF s1 NOT LIKE '%_rem_ok%' THEN
    s1 := replace(s1, $a$AND coalesce(py.method, '') NOT IN ('card', 'e_transfer', 'cheque', 'financing', 'autopay', 'cash') ON CONFLICT DO NOTHING;$a$,
      $a$AND (coalesce(py.method, '') NOT IN ('card', 'e_transfer', 'cheque', 'financing', 'autopay', 'cash')
           OR (py.method IN ('e_transfer', 'cheque') AND (py.notes ILIKE '%' || word || '%' OR concat_ws(' ', py.reference, py.notes) ~* '(^|[^0-9a-z])[a-z]?\d{4,6}([^0-9]|$)' AND py.notes !~* 'apprcode'))) /*_rem_ok*/ ON CONFLICT DO NOTHING;$a$);
    IF s1 NOT LIKE '%_rem_ok%' THEN RAISE EXCEPTION 'bank_partner_match: anchor not found'; END IF; EXECUTE s1; END IF;
  IF s2 NOT LIKE '%_not_partner%' THEN
    s2 := replace(s2, $a$WHEN 'etransfer' THEN p.method = 'e_transfer' OR p.notes ~* 'e-?transfer'$a$,
      $a$WHEN 'etransfer' THEN (p.method = 'e_transfer' OR p.notes ~* 'e-?transfer') AND NOT EXISTS (SELECT 1 FROM payment_applications pa2 JOIN invoices i2 ON i2.id = pa2.invoice_id WHERE pa2.payment_id = p.id AND i2.bill_to_partner_id IS NOT NULL) /*_not_partner*/$a$);
    s2 := replace(s2, $a$WHEN 'cheque' THEN p.method = 'cheque'$a$,
      $a$WHEN 'cheque' THEN p.method = 'cheque' AND NOT EXISTS (SELECT 1 FROM payment_applications pa2 JOIN invoices i2 ON i2.id = pa2.invoice_id WHERE pa2.payment_id = p.id AND i2.bill_to_partner_id IS NOT NULL)$a$);
    IF s2 NOT LIKE '%_not_partner%' THEN RAISE EXCEPTION 'bank_pay_match: anchor not found'; END IF; EXECUTE s2; END IF;
END $do$;
