-- The price the pricing rules give an item of a type at a cost (for adding items from a supplier quote)
CREATE OR REPLACE FUNCTION public.pb_rule_price_for(p_type text, p_cost numeric)
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN public.current_staff_role() IS NULL THEN NULL ELSE public._pb_rule_price(p_type, p_cost) END
$function$;
REVOKE EXECUTE ON FUNCTION public.pb_rule_price_for(text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pb_rule_price_for(text, numeric) TO authenticated;
NOTIFY pgrst, 'reload schema';
