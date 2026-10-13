/* AUREA BRAZIL - Financeiro: persistencia de recebimentos e cambio.
   Integrar ao index.html apos validar os formularios e autenticacao.
   Nunca importar registros antigos sem comprovacao para evitar duplicidade. */
(function(){
  const TABLE='aes_finance_order_movements';
  const client=()=>window.aesSharedClient;
  const currentOrder=()=>String(window.currentFinanceOrder||'').trim();
  const amount=(id)=>Number(document.getElementById(id)?.value||0);
  const value=(id)=>String(document.getElementById(id)?.value||'').trim();
  async function list(order,operationType='export'){
    const db=client();
    if(!db) throw new Error('Supabase indisponivel');
    const {data,error}=await db.from(TABLE).select('*').eq('order_number',order).eq('operation_type',operationType).order('created_at',{ascending:true});
    if(error) throw error;
    return data||[];
  }
  async function saveReceipt(operationType='export'){
    const db=client(),order=currentOrder(),sum=amount('finReceiptAmount');
    if(!db||!order) throw new Error('Sessao ou ordem indisponivel');
    if(!(sum>0)) throw new Error('Informe um valor valido');
    const {data:{user},error:authError}=await db.auth.getUser();
    if(authError||!user) throw new Error('Entre novamente no sistema');
    const record={order_number:order,operation_type:operationType,movement_type:'receipt',
      movement_date:value('finReceiptDate')||null,amount:sum,currency:'USD',
      bank:value('finReceiptBank'),reference:value('finReceiptRef'),payment_type:value('finReceiptType'),created_by:user.id};
    const {data,error}=await db.from(TABLE).insert(record).select().single();
    if(error) throw error;
    return data;
  }
  async function saveFx(operationType='export'){
    const db=client(),order=currentOrder(),sum=amount('finFxAmount'),rate=amount('finFxRate');
    if(!db||!order) throw new Error('Sessao ou ordem indisponivel');
    if(!(sum>0)) throw new Error('Informe valor de fechamento valido');
    const {data:{user},error:authError}=await db.auth.getUser();
    if(authError||!user) throw new Error('Entre novamente no sistema');
    const record={order_number:order,operation_type:operationType,movement_type:'fx_closing',
      movement_date:value('finFxDate')||null,amount:sum,currency:'USD',
      exchange_rate:rate>0?rate:null,bank:value('finFxBank'),reference:value('finFxContract'),created_by:user.id};
    const {data,error}=await db.from(TABLE).insert(record).select().single();
    if(error) throw error;
    return data;
  }
  window.aureaFinancePersistence={list,saveReceipt,saveFx,
    available:(rows)=>rows.filter(x=>x.movement_type==='receipt').reduce((a,x)=>a+Number(x.amount||0),0)-
      rows.filter(x=>x.movement_type==='fx_closing').reduce((a,x)=>a+Number(x.amount||0),0)};
})();