CREATE OR REPLACE FUNCTION public.aes_cash_commission_entries()
RETURNS SETOF jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $$
 select jsonb_build_object(
 'id','commission-'||d.id||'-'||md5(coalesce(nullif(c.value->>'number',''),c.ordinality::text)),
 'kind','commission','date',coalesce(nullif(c.value->>'issue_date',''),d.trade_date::text),
 'currency',coalesce(nullif(d.currency,''),'USD'),'bank_id',c.value->>'bank_id',
 'credit',round(case when c.value->>'method'='percent' then coalesce(nullif(c.value->>'base','')::numeric,0)*coalesce(nullif(c.value->>'rate','')::numeric,0)/100 else coalesce(nullif(c.value->>'rate','')::numeric,0) end,2),
 'debit',0,'party',coalesce(p.name,'—'),
 'invoice',concat_ws(' / ',nullif(c.value->>'number',''),d.trade_number),
 'order_number',d.trade_number,'description',concat_ws(' · ','Trader · Commission',nullif(c.value->>'sale_invoice',''),nullif(c.value->>'notes','')),
 'received',coalesce(nullif(c.value->>'received','')::numeric,0),'invoice_status',coalesce(c.value->>'invoice_status','pending'))
 from public.aes_trader_deals d
 cross join lateral jsonb_array_elements(case when jsonb_typeof(d.sale_flow->'commissions')='array' then d.sale_flow->'commissions' else '[]'::jsonb end) with ordinality c(value,ordinality)
 left join public.companies p on p.id::text=coalesce(nullif(c.value->>'payer',''),d.sale_flow->'parties'->>'exporter',d.trader_company_id::text)
 where d.sale_flow->>'deleted_at' is null and d.status is distinct from 'cancelled'
 and exists(select 1 from public.aes_cash_members where user_id=(select auth.uid()));
$$;
REVOKE ALL ON FUNCTION public.aes_cash_commission_entries() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aes_cash_commission_entries() TO authenticated;

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
 ) entries where exists(select 1 from public.aes_cash_members where user_id=(select auth.uid())) and exists(select 1 from public.aes_cash_banks where id=p_bank and status is distinct from 'Inactive');
$function$
