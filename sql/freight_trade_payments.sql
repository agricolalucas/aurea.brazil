CREATE OR REPLACE FUNCTION public.aes_cash_freight_entries() RETURNS SETOF jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
select jsonb_build_object('id','freight-'||f.id||'-'||v.side||'-'||(p->>'id'),
'date',p->>'date','currency',p->>'currency','bank_id',p->>'bank_id',
'credit',case when v.side='sale' then (p->>'amount')::numeric else 0 end,
'debit',case when v.side='purchase' then (p->>'amount')::numeric else 0 end,
'party',c.name,'invoice',f.trade_number,'order_number',f.trade_number,
'description',concat_ws(' · ','Frete Trade',p->>'reference'),'kind','freight')
from public.aes_freight_trades f
cross join lateral (values ('purchase',f.purchase_flow),('sale',f.sale_flow)) v(side,flow)
cross join lateral jsonb_array_elements(coalesce(v.flow->'payments','[]')) p
left join public.companies c on c.id=case when v.side='purchase' then f.supplier_id else f.customer_id end
where f.status<>'cancelled' and (p->>'amount')::numeric>0 and coalesce(p->>'id','')<>''
and exists(select 1 from public.aes_cash_members where user_id=(select auth.uid()));
$$;
REVOKE ALL ON FUNCTION public.aes_cash_freight_entries() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.aes_cash_freight_entries() TO authenticated;
CREATE OR REPLACE FUNCTION public.aes_cash_bank_system_entries(p_bank bigint, p_currency text)
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 select x from (
 select jsonb_build_object('id','sales-'||i.id,'date',i.invoice_date,'currency',i.currency,'credit',i.amount_try,'debit',0,'party',i.buyer_company,'invoice',i.invoice_number,'description',coalesce(i.details->>'product',i.details->>'product_name','')) x from public.aes_cash_sales_invoices i where i.currency=p_currency and i.amount_try>0 and i.status is distinct from 'Cancelled'
 union all
 select jsonb_build_object('id','expense-'||e.id,'date',e.expense_date,'currency',e.currency,'credit',0,'debit',e.total_amount,'party',e.supplier_company,'invoice',e.tax_invoice_number,'gstin',coalesce(e.details->>'gstin',''),'description',coalesce(e.details->>'description','')) from public.aes_cash_gst_expenses e where e.currency=p_currency and e.total_amount>0
 union all
 select jsonb_build_object('id','order-'||o.id,'date',o.payment_date,'currency',case when o.currency='USD' and o.details->>'conversionMode' is distinct from 'none' and o.details->>'convertedTry' is not null then 'TRY' else o.currency end,'credit',0,'debit',case when o.currency='USD' and o.details->>'conversionMode' is distinct from 'none' and o.details->>'convertedTry' is not null then (o.details->>'convertedTry')::numeric else o.amount end,'party',coalesce(o.details->>'exporter','Order payment'),'invoice',o.shipment_reference,'description',concat_ws(' · ',o.details->>'bankReference',o.details->>'notes'),'kind','order') from public.aes_cash_order_payments o join public.aes_cash_banks b on b.id=p_bank where o.details->>'deletedAt' is null and o.amount>0 and (o.bank_id=p_bank or (o.bank_id is null and o.bank in (p_bank::text,concat_ws(' · ',b.bank_name,b.beneficiary_name,case when coalesce(b.account_number,'')<>'' then 'A/C '||b.account_number end,coalesce(nullif(b.swift,''),b.ifsc)),concat_ws(' · ',b.bank_name,b.account_number,b.beneficiary_name)))) and (case when o.currency='USD' and o.details->>'conversionMode' is distinct from 'none' and o.details->>'convertedTry' is not null then 'TRY' else o.currency end)=p_currency
 union all
 select jsonb_build_object('id','financial-'||f.id,'date',f.entry_date,'currency',f.currency,'credit',f.credit,'debit',f.debit,'party','Financial Expense','invoice',f.reference,'description',f.description,'kind','financial') from public.aes_cash_bank_financial_entries f where f.bank_id=p_bank and f.currency=p_currency and f.kind='manual'

 union all
 select jsonb_build_object('id','receipt-'||r.id,'date',r.movement_date,'currency',coalesce(r.currency,'USD'),
 'credit',case when (r.movement_type='receipt' and lower(r.order_number) !~ '^trader:[0-9a-f-]{36}:purchase$') then r.amount else 0 end,
 'debit',case when (r.movement_type='receipt' and lower(r.order_number) !~ '^trader:[0-9a-f-]{36}:purchase$') then 0 else r.amount end,
 'party',r.order_number,'invoice',coalesce(nullif(d.trade_number,''),r.order_number),
 'description',concat_ws(' · ',r.reference,r.payment_type),'kind','receipt')
 from public.aes_finance_order_movements r
 join public.aes_cash_banks b on b.id=p_bank
 left join public.aes_trader_deals d on d.id::text=split_part(r.order_number,':',2) and r.order_number like 'TRADER:%'
 where r.amount>0 and coalesce(r.currency,'USD')=p_currency
 and lower(trim(coalesce(r.bank,''))) in (lower(trim(b.bank_name)),b.id::text,
 lower(trim(concat_ws(' · ',b.bank_name,b.beneficiary_name,case when coalesce(b.account_number,'')<>'' then 'A/C '||b.account_number end,coalesce(nullif(b.swift,''),b.ifsc)))),
 lower(trim(concat_ws(' · ',b.bank_name,b.account_number,b.beneficiary_name))))

 union all
 select c from public.aes_cash_commission_entries() c
 join public.aes_cash_banks b on b.id=p_bank
 where c->>'currency'=p_currency and (c->>'credit')::numeric>0
 and c->>'bank_id' in (b.id::text,b.details->>'id')
 union all
 select c from public.aes_cash_freight_entries() c join public.aes_cash_banks b on b.id=p_bank
 where c->>'currency'=p_currency and c->>'bank_id' in (b.id::text,b.details->>'id')
 ) entries where exists(select 1 from public.aes_cash_members where user_id=(select auth.uid())) and exists(select 1 from public.aes_cash_banks where id=p_bank and status is distinct from 'Inactive');
$function$

CREATE OR REPLACE FUNCTION public.aes_freight_payment_lock() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE v record; p jsonb; replacement jsonb;
BEGIN
FOR v IN SELECT 'purchase' side,OLD.purchase_flow flow,NEW.purchase_flow nextflow UNION ALL SELECT 'sale',OLD.sale_flow,NEW.sale_flow LOOP
FOR p IN SELECT value FROM jsonb_array_elements(coalesce(v.flow->'payments','[]')) LOOP
IF EXISTS(SELECT 1 FROM public.aes_cash_bank_match_items i JOIN public.aes_cash_bank_matches m ON m.id=i.match_id WHERE i.system_key='freight-'||OLD.id||'-'||v.side||'-'||(p->>'id')) THEN
SELECT value INTO replacement FROM jsonb_array_elements(coalesce(v.nextflow->'payments','[]')) WHERE value->>'id'=p->>'id';
IF replacement IS DISTINCT FROM p OR NEW.status='cancelled' THEN RAISE EXCEPTION 'Desconcilie o pagamento do frete antes de alterar, excluir ou cancelar.'; END IF;
END IF;
END LOOP;
END LOOP;
RETURN NEW; END $$;
CREATE TRIGGER aes_freight_payment_lock BEFORE UPDATE ON public.aes_freight_trades FOR EACH ROW EXECUTE FUNCTION public.aes_freight_payment_lock();