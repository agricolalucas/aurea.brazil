create table if not exists aes_cash_private.bank_match_undo (
 match_id uuid primary key,bank_id bigint not null,currency text not null,
 undone_by uuid not null,undone_at timestamptz not null default now(),
 match_snapshot jsonb not null,item_snapshots jsonb not null,adjustment_snapshots jsonb not null
);
alter table aes_cash_private.bank_match_undo enable row level security;
revoke all on aes_cash_private.bank_match_undo from public,anon,authenticated;
CREATE OR REPLACE FUNCTION aes_cash_private.bank_operation(p_action text, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid:=auth.uid(); bid bigint:=(p_data->>'bank_id')::bigint; cur text:=p_data->>'currency';op uuid:=(p_data->>'id')::uuid; r jsonb; source jsonb; tid uuid; fp text; inserted integer:=0;skipped integer:=0;bc numeric:=0;bd numeric:=0;sc numeric:=0;sd numeric:=0;ids uuid[];keys text[];bankrow public.aes_cash_bank_transactions%rowtype; delta numeric; aid uuid; description text; amount numeric; rate numeric; existing uuid;
begin
 if u is null or not exists(select 1 from public.aes_cash_members where user_id=u) then raise exception 'Project membership required';end if;
 if not exists(select 1 from public.aes_cash_banks where id=bid and status is distinct from 'Inactive') or cur is null or cur not in ('INR','USD','EUR','EGP','BRL','AED','GBP','CNY','VND','TRY') then raise exception 'Select an active bank and currency';end if;
 perform pg_advisory_xact_lock(7426270810); -- Shares the payment ledger lock.
 if p_action='financial_save' then
  if coalesce(p_data->>'direction','debit') not in ('debit','credit') then raise exception 'Select debit or credit';end if;
  amount:=(p_data->>'amount')::numeric;description:=trim(coalesce(p_data->>'description',''));
  if amount is null or amount<=0 or amount<>round(amount,2) or description='' or length(description)>500 or length(coalesce(p_data->>'reference',''))>200 or nullif(p_data->>'date','') is null then raise exception 'Date, description and positive amount required';end if;
  if exists(select 1 from public.aes_cash_bank_financial_entries where id=op and bank_id=bid) then return jsonb_build_object('id',op,'already_saved',true);end if;
  insert into public.aes_cash_bank_financial_entries(id,bank_id,currency,entry_date,description,reference,debit,credit,kind,created_by) values(op,bid,cur,(p_data->>'date')::date,description,coalesce(p_data->>'reference',''),case when coalesce(p_data->>'direction','debit')='debit' then amount else 0 end,case when p_data->>'direction'='credit' then amount else 0 end,'manual',u);
  return jsonb_build_object('id',op);
 elsif p_action='unmatch' then
  perform 1 from public.aes_cash_bank_matches where id=op and bank_id=bid and currency=cur for update;
  if not found then raise exception 'Reconciliation unavailable. Refresh the screen';end if;
  insert into aes_cash_private.bank_match_undo(match_id,bank_id,currency,undone_by,match_snapshot,item_snapshots,adjustment_snapshots)
  select m.id,m.bank_id,m.currency,u,to_jsonb(m),
   coalesce((select jsonb_agg(to_jsonb(i)) from public.aes_cash_bank_match_items i where i.match_id=m.id),'[]'::jsonb),
   coalesce((select jsonb_agg(to_jsonb(f)) from public.aes_cash_bank_financial_entries f where f.match_id=m.id and f.kind='adjustment'),'[]'::jsonb)
  from public.aes_cash_bank_matches m where m.id=op;
  delete from public.aes_cash_bank_match_items where match_id=op;
  delete from public.aes_cash_bank_financial_entries where match_id=op and kind='adjustment';
  delete from public.aes_cash_bank_matches where id=op and bank_id=bid and currency=cur;
  return jsonb_build_object('id',op,'unmatched',true);
 elsif p_action='order_save' then
  select id into existing from public.aes_cash_order_payments where details->>'legacy_id'=p_data->>'legacy_id';
  if existing is not null then return jsonb_build_object('id',existing,'already_saved',true);end if;
  amount:=(p_data->>'amountUsd')::numeric;rate:=case when p_data->>'conversionMode'='none' then null else (p_data->>'usdTryRate')::numeric end;
  if amount is null or amount<=0 or amount<>round(amount,2) or (p_data->>'conversionMode' is distinct from 'none' and (rate is null or rate<=0)) or cur<>'USD' or coalesce(p_data->>'conversionMode','try') not in ('try','none') or nullif(p_data->>'paymentDate','') is null or trim(coalesce(p_data->>'orderRef',''))='' then raise exception 'Complete order, payment date, USD amount and rate';end if;
  insert into public.aes_cash_order_payments(id,shipment_reference,payment_date,currency,amount,bank,bank_id,details,created_by) values(op,p_data->>'orderRef',(p_data->>'paymentDate')::date,'USD',amount,bid::text,bid,jsonb_build_object('legacy_id',p_data->>'legacy_id','amountUsd',amount,'usdTryRate',rate,'convertedTry',round(amount*rate,2),'conversionMode',coalesce(p_data->>'conversionMode','try'),'bankReference',coalesce(p_data->>'bankReference',''),'notes',coalesce(p_data->>'notes',''),'exporter',coalesce(p_data->>'exporter',''),'orderDisplay',coalesce(p_data->>'orderDisplay','')),u);
  return jsonb_build_object('id',op);
 elsif p_action='order_delete' then
  if not exists(select 1 from public.aes_cash_members where user_id=u and role='admin') then raise exception 'Administrator access is required to delete order payments';end if;
  select id into existing from public.aes_cash_order_payments where id=op and bank_id=bid and currency=cur for update;
  if existing is null then raise exception 'Order payment unavailable. Refresh the screen';end if;
  if exists(select 1 from public.aes_cash_bank_match_items where system_key='order-'||op::text) then raise exception 'This payment is reconciled and cannot be deleted';end if;
  update public.aes_cash_order_payments set details=details||jsonb_build_object('deletedAt',now(),'deletedBy',u) where id=op and details->>'deletedAt' is null;
  return jsonb_build_object('id',op,'deleted',true);
 elsif p_action='import' then
  if exists(select 1 from public.aes_cash_bank_statements where id=op and bank_id=bid) then return jsonb_build_object('already_saved',true);end if;
  if exists(select 1 from public.aes_cash_bank_statements where bank_id=bid and file_sha256=p_data->>'file_sha256' and sheet_name=p_data->>'sheet_name') then raise exception 'This original statement file was already imported';end if;
  if not exists(select 1 from storage.objects where bucket_id='aes_cash-bank-statements' and name=p_data->>'storage_path' and (storage.foldername(name))[1]=u::text) then raise exception 'Original file must be uploaded before import';end if;
  if jsonb_typeof(p_data->'rows') is distinct from 'array' or jsonb_array_length(p_data->'rows')=0 then raise exception 'No valid transactions selected';end if;
  insert into public.aes_cash_bank_statements(id,bank_id,currency,file_name,storage_path,file_sha256,sheet_name,import_options,raw_rows,created_by) values(op,bid,cur,p_data->>'file_name',p_data->>'storage_path',p_data->>'file_sha256',p_data->>'sheet_name',p_data->'options',p_data->'raw_rows',u);
  for r in select value from jsonb_array_elements(p_data->'rows') loop
   if (r->>'debit')::numeric<0 or (r->>'credit')::numeric<0 or round((r->>'debit')::numeric,2)<>(r->>'debit')::numeric or round((r->>'credit')::numeric,2)<>(r->>'credit')::numeric then raise exception 'Invalid debit / credit amount';end if;
   fp:=encode(sha256(convert_to(jsonb_build_array((r->>'date')::date,nullif(r->>'value_date','')::date,lower(regexp_replace(trim(coalesce(r->>'description','')),'\s+',' ','g')),lower(trim(coalesce(r->>'reference',''))),(r->>'debit')::numeric,(r->>'credit')::numeric,nullif(r->>'balance','')::numeric)::text,'UTF8')),'hex');
   tid:=null;
   insert into public.aes_cash_bank_transactions(statement_id,bank_id,currency,transaction_date,value_date,description,reference,bank_serial,branch_name,channel,transaction_type,debit,credit,balance,source_row,fingerprint,import_metadata) values(op,bid,cur,(r->>'date')::date,nullif(r->>'value_date','')::date,coalesce(r->>'description',''),coalesce(r->>'reference',''),coalesce(r->>'bank_serial',''),coalesce(r->>'branch_name',''),coalesce(r->>'channel',''),coalesce(r->>'transaction_type',''),(r->>'debit')::numeric,(r->>'credit')::numeric,nullif(r->>'balance','')::numeric,(r->>'source_row')::integer,fp,coalesce(r->'import_metadata','{}'::jsonb)) on conflict(bank_id,currency,fingerprint) do nothing returning id into tid;
   if tid is null then skipped:=skipped+1;else inserted:=inserted+1;end if;
  end loop;
  if inserted=0 then raise exception 'All selected transactions already exist; nothing imported';end if;
  return jsonb_build_object('id',op,'imported',inserted,'duplicates_skipped',skipped);
 elsif p_action='match' then
  if exists(select 1 from public.aes_cash_bank_matches where id=op and bank_id=bid) then return jsonb_build_object('already_saved',true);end if;
  select array_agg(v::uuid) into ids from jsonb_array_elements_text(p_data->'transaction_ids') v;
  select array_agg(v) into keys from jsonb_array_elements_text(p_data->'system_keys') v;
  if coalesce(cardinality(ids),0)=0 or coalesce(cardinality(keys),0)=0 then raise exception 'Select rows on both sides';end if;
  if cardinality(ids)<>(select count(distinct v) from unnest(ids) v) or cardinality(keys)<>(select count(distinct v) from unnest(keys) v) then raise exception 'Repeated selection';end if;
  -- Lock source records before taking authoritative snapshots.
  perform 1 from public.aes_cash_sales_invoices where 'sales-'||id=any(keys);
  perform 1 from public.aes_cash_gst_expenses where 'expense-'||id=any(keys) for update;
  perform 1 from public.aes_cash_order_payments where 'order-'||id=any(keys) for update;
  perform 1 from public.aes_cash_bank_financial_entries where 'financial-'||id=any(keys) for update;
  perform 1 from public.aes_finance_order_movements where 'receipt-'||id=any(keys) for update;
  for bankrow in select * from public.aes_cash_bank_transactions where id=any(ids) and bank_id=bid and currency=cur for update loop bc:=bc+bankrow.credit;bd:=bd+bankrow.debit;end loop;
  if (select count(*) from public.aes_cash_bank_transactions where id=any(ids) and bank_id=bid and currency=cur)<>cardinality(ids) then raise exception 'Bank transaction unavailable';end if;
  if exists(select 1 from public.aes_cash_bank_match_items where transaction_id=any(ids) or system_key=any(keys)) then raise exception 'A selected entry was already reconciled. Refresh the screen';end if;
  for source in select x from public.aes_cash_bank_system_entries(bid,cur) x where x->>'id'=any(keys) loop sc:=sc+(source->>'credit')::numeric;sd:=sd+(source->>'debit')::numeric;end loop;
  if (select count(*) from public.aes_cash_bank_system_entries(bid,cur) x where x->>'id'=any(keys))<>cardinality(keys) then raise exception 'System entry changed or unavailable. Refresh';end if;
  delta:=round(bc-bd-sc+sd,2);
  if delta<>0 then
   description:=trim(coalesce(p_data->'adjustment'->>'description',''));amount:=(p_data->'adjustment'->>'amount')::numeric;
   if description='' or length(description)>500 or amount is null or amount<>abs(delta) then raise exception 'Enter a description and the exact difference amount';end if;
  elsif p_data->'adjustment' is not null and p_data->'adjustment'<>'null'::jsonb then raise exception 'No adjustment required when difference is zero';end if;
  insert into public.aes_cash_bank_matches(id,bank_id,currency,credit,debit,notes,created_by) values(op,bid,cur,bc,bd,coalesce(p_data->>'notes',''),u);
  insert into public.aes_cash_bank_match_items(match_id,side,transaction_id,snapshot) select op,'bank',id,to_jsonb(t) from public.aes_cash_bank_transactions t where id=any(ids);
  insert into public.aes_cash_bank_match_items(match_id,side,system_key,snapshot) select op,'system',x->>'id',x from public.aes_cash_bank_system_entries(bid,cur) x where x->>'id'=any(keys);
  if delta<>0 then
   aid:=gen_random_uuid();
   insert into public.aes_cash_bank_financial_entries(id,bank_id,currency,entry_date,description,debit,credit,kind,match_id,created_by) values(aid,bid,cur,(select min(transaction_date) from public.aes_cash_bank_transactions where id=any(ids)),description,case when delta<0 then -delta else 0 end,case when delta>0 then delta else 0 end,'adjustment',op,u);
   insert into public.aes_cash_bank_match_items(match_id,side,system_key,snapshot) values(op,'system','adjustment-'||aid,jsonb_build_object('id','adjustment-'||aid,'date',(select min(transaction_date) from public.aes_cash_bank_transactions where id=any(ids)),'currency',cur,'party','Lançamento avulso','description',description,'invoice','Ajuste de conciliação','credit',case when delta>0 then delta else 0 end,'debit',case when delta<0 then -delta else 0 end));
   update public.aes_cash_bank_matches set notes=concat_ws(' / ',nullif(notes,''),'Lançamento avulso: '||description||' · '||case when delta>0 then 'Crédito' else 'Débito' end||' '||abs(delta)::text||' · Diferença final 0.00') where id=op;
  end if;
  return jsonb_build_object('id',op);
 else raise exception 'Unknown bank operation';end if;
end$function$
