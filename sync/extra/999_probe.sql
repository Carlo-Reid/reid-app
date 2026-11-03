DO $$ BEGIN RAISE EXCEPTION 'PROBE %', (SELECT count(*) || ' lines; partner deposits ' || count(*) FILTER (WHERE amount_in > 0 AND description ~* '^(VISTACREDIT|COSTCO|RONA INC|LOWE)') || '; ' ||
  (SELECT string_agg(d, ' | ') FROM (SELECT txn_date || ' ' || left(description, 22) || ' o=' || amount_out || ' i=' || amount_in || ' b=' || coalesce(balance::text,'-') d FROM bank_transactions WHERE file_name = 'Book3.xlsx' ORDER BY txn_date, id LIMIT 3) s)
  FROM bank_transactions WHERE file_name = 'Book3.xlsx'); END $$;
