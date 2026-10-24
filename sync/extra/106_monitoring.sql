-- =====================================================================
-- Improvement 6: the Monitoring page (owners). The monitoring contracts table is empty, so this builds the list from
-- what's real: customers billed under Security Monitoring, and the people on the EFT (bank) lists.
-- Each one shows the last monitoring bill, what the bank said last time (approved / returned NSF), what's owing,
-- and flags: payment returned, billed but not on EFT, on EFT but not billed. Returned ones get a "Make a task" button.
-- Safe to run more than once.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._eft_said(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN coalesce(btrim(p), '') = '' THEN NULL
              WHEN p ~* '(nsf|insuff|return|reject|declin|stop|closed|invalid|fail|frozen|refus|no account|chargeback|revers)' THEN 'returned'
              WHEN p ~* '(approv|accept|success|settled|paid|complete|^ok$|^ok\M)' THEN 'ok'
              ELSE 'other' END
$$;

CREATE OR REPLACE FUNCTION public.monitoring_accounts()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public SET statement_timeout = '60s' AS $$
DECLARE v jsonb; eft jsonb;
BEGIN
  IF NOT coalesce(public._is_owner(), false) THEN RETURN NULL; END IF;
  BEGIN eft := public.pap_file_people() -> 'rows'; EXCEPTION WHEN undefined_function THEN eft := '[]'; END;
  WITH bu AS (SELECT id FROM business_units WHERE name ILIKE '%monitor%'),
  bill AS (SELECT i.customer_id, max(i.invoice_date) AS last, (array_agg(i.total ORDER BY i.invoice_date DESC, i.id DESC))[1] AS last_amount,
                  count(*) FILTER (WHERE i.invoice_date >= current_date - 395) AS bills_13m, coalesce(sum(i.balance_due) FILTER (WHERE i.balance_due > 0.004 AND i.bad_debt_at IS NULL AND i.not_owed_at IS NULL), 0) AS owing
           FROM invoices i WHERE i.business_unit_id IN (SELECT id FROM bu) AND i.status <> 'draft' AND i.customer_id IS NOT NULL GROUP BY i.customer_id),
  e AS (SELECT DISTINCT ON ((x ->> 'customer_id')::bigint) (x ->> 'customer_id')::bigint AS customer_id, x ->> 'response' AS response, x ->> 'amount' AS amount,
               (x ->> 'received')::timestamptz AS received, x ->> 'file' AS file, x ->> 'file_list' AS list
        FROM jsonb_array_elements(coalesce(eft, '[]')) x WHERE x ->> 'customer_id' ~ '^\d+$'
        ORDER BY (x ->> 'customer_id')::bigint, (x ->> 'received') DESC NULLS LAST),
  ids AS (SELECT customer_id FROM bill UNION SELECT customer_id FROM e),
  r AS (SELECT c.id, c.display_name, c.customer_number, c.pap_list, b.last, b.last_amount, b.bills_13m, coalesce(b.owing, 0) AS owing,
               e.response, public._eft_said(e.response) AS said, e.amount, e.received, e.file, e.list,
               (SELECT count(*) FROM follow_ups f WHERE f.customer_id = c.id AND f.done_at IS NULL AND f.completed_at IS NULL) AS tasks,
               CASE WHEN public._eft_said(e.response) = 'returned' THEN 'returned'
                    WHEN e.customer_id IS NULL AND c.pap_list IS NULL THEN 'no_eft'
                    WHEN b.customer_id IS NULL OR b.bills_13m = 0 THEN 'not_billed'
                    ELSE 'ok' END AS flag
        FROM ids JOIN customers c ON c.id = ids.customer_id AND c.merged_into_id IS NULL
        LEFT JOIN bill b ON b.customer_id = c.id LEFT JOIN e ON e.customer_id = c.id)
  SELECT jsonb_build_object(
    'counts', (SELECT jsonb_build_object('all', count(*), 'returned', count(*) FILTER (WHERE flag = 'returned'), 'no_eft', count(*) FILTER (WHERE flag = 'no_eft'),
                                         'not_billed', count(*) FILTER (WHERE flag = 'not_billed'), 'ok', count(*) FILTER (WHERE flag = 'ok'),
                                         'billed', count(*) FILTER (WHERE bills_13m > 0), 'owing', coalesce(sum(owing), 0)) FROM r),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('customer_id', id, 'name', display_name, 'number', customer_number, 'pap_list', pap_list,
                'last', last, 'last_amount', last_amount, 'bills_13m', coalesce(bills_13m, 0), 'owing', owing, 'response', response, 'said', said, 'amount', amount,
                'received', received, 'file', file, 'list', list, 'tasks', tasks, 'flag', flag,
                'address', (SELECT concat_ws(', ', l.street, l.city) FROM locations l WHERE l.customer_id = r.id ORDER BY l.active DESC, l.id LIMIT 1))
              ORDER BY CASE flag WHEN 'returned' THEN 0 WHEN 'no_eft' THEN 1 WHEN 'not_billed' THEN 2 ELSE 3 END, lower(display_name)) FROM r), '[]'))
  INTO v;
  RETURN v;
END $$;
REVOKE EXECUTE ON FUNCTION public.monitoring_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitoring_accounts() TO authenticated;

NOTIFY pgrst, 'reload schema';
