/* Persistent claim evidence and weight-shortage comparison. */
(function(){
'use strict';
const bucket='aes-claim-evidence',groups={claimEvidenceFiles:'Fotos / Vídeos / Laudos',claimShippingDocs:'Documentos de embarque',claimLossProof:'Comprovante do prejuízo',claimClientTicket:'Ticket do cliente',claimAureaTicket:'Ticket da Áurea'};
const $=id=>document.getElementById(id), esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let busy=false;
const cached=new WeakMap();
function calc(w){const a=Number(w.aurea),c=Number(w.client),valid=w.aurea!==''&&w.client!==''&&Number.isFinite(a)&&Number.isFinite(c)&&a>0&&c>=0;return {valid,diff:a-c,short:Math.max(0,a-c),percent:valid?Math.max(0,a-c)/a*100:0,value:Math.max(0,a-c)/1000*Number(w.price||0)};}
function weights(){return {aurea:$('claimAureaKg').value,client:$('claimClientKg').value,price:$('claimShortagePrice').value};}
const fmt=n=>Number(n).toLocaleString('pt-BR',{maximumFractionDigits:3});
function comparison(w){const r=calc(w);return r.valid?`Diferença (Áurea − cliente): ${fmt(r.diff)} kg · Falta: ${fmt(r.short)} kg (${fmt(r.percent)}%)${w.price!==''?' · Valor estimado: '+esc($('claimCurrency').value)+' '+fmt(r.value):''}`:'Informe os dois pesos líquidos para comparar os tickets.';}
function install(){if($('claimWeightComparison'))return;const card=document.createElement('div');card.className='card';card.id='claimWeightComparison';card.innerHTML=`<h2 style="font-size:18px;margin-top:0">Falta de peso · Comparação dos tickets</h2><div class="grid2"><div><label>Ticket enviado pelo cliente</label><input id="claimClientTicket" type="file" multiple accept="application/pdf,image/*"><label>Peso líquido do cliente (kg)</label><input id="claimClientKg" type="number" min="0" step="0.001"></div><div><label>Nosso ticket · Áurea</label><input id="claimAureaTicket" type="file" multiple accept="application/pdf,image/*"><label>Peso líquido Áurea (kg)</label><input id="claimAureaKg" type="number" min="0" step="0.001"></div></div><label>Preço por tonelada (moeda da reclamação) · opcional</label><input id="claimShortagePrice" type="number" min="0" step="0.01"><p class="sub">Digite os pesos líquidos constantes nos tickets, na mesma unidade (kg).</p><p id="claimWeightResult" role="status"></p>`;
const evidence=$('claimEvidenceFiles').closest('.card');evidence.after(card);
for(const id of Object.keys(groups)){const list=document.createElement('div');list.id=id+'Saved';list.style.marginTop='8px';$(id).after(list);}
const button=document.createElement('button');button.type='button';button.textContent='Gerar relatório · PDF';button.onclick=report;card.after(button);button.style.margin='0 0 16px 16px';
$('claimType').addEventListener('change',visibility);['claimAureaKg','claimClientKg','claimShortagePrice','claimCurrency'].forEach(id=>$(id).addEventListener('input',()=>{$('claimWeightResult').textContent=comparison(weights());}));}
function visibility(){$('claimWeightComparison').style.display=$('claimType').value==='Weight Shortage'?'block':'none';}
function show(d){install();for(const id of Object.keys(groups)){$(id).value='';const list=$(id+'Saved');list.replaceChildren();for(const f of (d.evidence||[]).filter(x=>x.category===id)){const a=document.createElement('button');a.type='button';a.className='btn';a.textContent=f.name;a.style.cssText='display:block;margin:4px 0;max-width:100%;overflow-wrap:anywhere';a.onclick=async()=>{try{const {data,error}=await window.aesSharedClient.storage.from(bucket).download(f.path);if(error)throw error;const url=URL.createObjectURL(data);const link=document.createElement('a');link.href=url;link.download=f.name;link.click();setTimeout(()=>URL.revokeObjectURL(url),60000);}catch(e){notify('Não foi possível abrir o anexo: '+e.message);}};list.append(a);}}
const w=d.weightComparison||{};$('claimAureaKg').value=w.aurea??'';$('claimClientKg').value=w.client??'';$('claimShortagePrice').value=w.price??'';$('claimWeightResult').textContent=comparison(weights());visibility();}
async function prepare(d){install();d.weightComparison=weights();const w=d.weightComparison;for(const v of Object.values(w))if(v!==''&&(!Number.isFinite(Number(v))||Number(v)<0))throw Error('Informe pesos e preço válidos, maiores ou iguais a zero.');
const db=window.aesSharedClient;const pending=Object.keys(groups).flatMap(id=>Array.from($(id).files||[]).map(file=>({id,file})));if(!pending.length)return;
const {data,error}=await db.auth.getUser();if(error||!data?.user)throw Error('Entre novamente para enviar os anexos.');d.evidence=Array.isArray(d.evidence)?d.evidence:[];
for(const {id,file} of pending){if(file.size>52428800)throw Error('O arquivo '+file.name+' excede 50 MB.');let item=cached.get(file);if(!item||item.claim!==d.id){const safe=file.name.normalize('NFKD').replace(/[^a-zA-Z0-9._-]/g,'_');const path=data.user.id+'/'+d.id+'/'+id+'/'+crypto.randomUUID()+'-'+safe;const result=await db.storage.from(bucket).upload(path,file,{upsert:false,contentType:file.type||'application/octet-stream'});if(result.error)throw Error('Falha no envio de '+file.name+': '+result.error.message);item={claim:d.id,category:id,path,name:file.name,size:file.size,type:file.type,uploadedAt:new Date().toISOString()};cached.set(file,item);}if(!d.evidence.some(x=>x.path===item.path))d.evidence.push(item);}}
function reportOrders(claim){
 const links=Array.isArray(claim.orderLinks)?claim.orderLinks.filter(link=>link?.number):[];
 const combined=String(claim.booking||'').split(/\s+\/\s+|[,;\n]/).map(value=>value.trim()).filter(Boolean);
 const rows=links.length?links.map(link=>({
  order:link.number,
  bookings:Array.isArray(link.bookings)?link.bookings.filter(Boolean):[]
 })):claim.order?[{order:claim.order,bookings:combined}]:[];
 const known=new Set(rows.flatMap(row=>row.bookings).map(booking=>String(booking).trim().toLowerCase()));
 const other=combined.filter(booking=>!known.has(booking.toLowerCase()));
 return (rows.length?'<h2>Ordens e bookings vinculados</h2><table><thead><tr><th>Ordem</th><th>Booking</th></tr></thead><tbody>'+
  rows.map(row=>'<tr><td>'+esc(row.order)+'</td><td>'+esc(row.bookings.join(' / ')||'Sem booking vinculado')+'</td></tr>').join('')+'</tbody></table>':'')+
  (other.length?'<p><b>Booking / BL informado:</b> '+esc(other.join(' / '))+'</p>':'');
}
async function report(){
 if(busy)return;
 const win=window.open('','_blank');
 if(!win){notify('Permita a abertura da janela para gerar o PDF.');return;}
 const claimId=window.currentClaimId;
 win.document.write('<p>Salvando reclamação e preparando relatório…</p>');
 const ok=await window.saveClaim();
 if(!ok){win.close();return;}
 const d=window.claimData[claimId],w=d.weightComparison||{},r=calc(w);
 const rawLogo=await window.aesClaimOrderPicker?.reportLogo?.();
 const logo=/^(data:image\/(?:png|jpe?g|webp|gif);base64,|https?:\/\/)/i.test(rawLogo||'')?rawLogo:'';
 if(win.closed)return;
 const rows=[['Importador',d.importer],['Data',d.openDate],['Tipo',d.type],['Situação',d.status]];
 const block=(title,text)=>text?`<h2>${title}</h2><p>${esc(text).replace(/\n/g,'<br>')}</p>`:'';
win.document.open();win.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Relatório ${esc(d.id)}</title><style>@page{size:A4;margin:16mm}body{font:12px Arial;color:#17364b}header{display:flex;align-items:center;gap:15px;border-bottom:3px solid #17364b;padding-bottom:14px}header img{max-width:130px;max-height:58px;object-fit:contain}h1{font-size:20px}h2{font-size:14px;margin-top:24px}table{width:100%;border-collapse:collapse;margin:12px 0}th,td{border:1px solid #d1dce6;padding:9px;text-align:left}th{background:#edf3f8}p{line-height:1.5;overflow-wrap:anywhere}tr{break-inside:avoid}@media print{button{display:none}}</style></head><body><button onclick="window.print()">Imprimir / Salvar PDF</button><header>${logo?`<img id="claimReportAureaLogo" src="${esc(logo)}" alt="Aurea">`:``}<div><b>ÁUREA · EXPORT SYSTEM</b><h1>Relatório de reclamação · ${esc(d.id)}</h1></div></header><table>${rows.map(([a,b])=>`<tr><th>${a}</th><td>${esc(b||'—')}</td></tr>`).join('')}</table>${reportOrders(d)}${d.type==='Weight Shortage'?`<h2>Comparação dos tickets · pesos líquidos</h2><table><tr><th>Nosso ticket · Áurea</th><th>Ticket do cliente</th><th>Falta</th><th>Percentual</th></tr><tr><td>${w.aurea!==''&&w.aurea!=null?fmt(w.aurea)+' kg':'Não informado'}</td><td>${w.client!==''&&w.client!=null?fmt(w.client)+' kg':'Não informado'}</td><td>${r.valid?fmt(r.short)+' kg':'—'}</td><td>${r.valid?fmt(r.percent)+'%':'—'}</td></tr></table><p>${r.valid?'Diferença (Áurea − cliente): '+fmt(r.diff)+' kg. ':''}${w.price!==''&&w.price!=null&&r.valid?'Preço por tonelada: '+esc(d.currency)+' '+fmt(w.price)+'. Valor estimado da falta: '+esc(d.currency)+' '+fmt(r.value)+'.':''}</p>`:''}${block('Descrição',d.description)}${block('Análise / Causa',d.analysis)}${block('Resposta ao importador',d.response)}<h2>Evidências salvas</h2><table><tr><th>Categoria</th><th>Arquivo</th></tr>${(d.evidence||[]).map(f=>`<tr><td>${esc(groups[f.category]||f.category)}</td><td>${esc(f.name)}</td></tr>`).join('')||'<tr><td colspan="2">Nenhum anexo salvo.</td></tr>'}</table><p>Decisão: ${esc(d.decision||'—')} · Valor aprovado: ${esc(d.currency)} ${fmt(d.approvedAmount||0)}</p></body></html>`);win.document.close();
 const image=win.document.getElementById('claimReportAureaLogo');
 if(image){
  let timer;
  try{await Promise.race([image.decode(),new Promise(resolve=>{timer=setTimeout(resolve,8000);})]);}
  catch{image.remove();}
  finally{clearTimeout(timer);}
 }
 if(!win.closed){win.focus();win.print();}
}
const originalOpen=window.openClaim,originalSave=window.saveClaim;
window.openClaim=function(id){if(busy)return notify('Aguarde o término do envio dos anexos.');if(Object.keys(groups).some(k=>$(k)?.files?.length))return notify('Salve os anexos selecionados antes de abrir outra reclamação.');originalOpen(id);if(window.claimData[id])show(window.claimData[id]);};
window.saveClaim=async function(){if(busy)return false;busy=true;const controls=Array.from($('claimWorkspace').querySelectorAll('input,select,textarea,button'));try{controls.forEach(x=>x.disabled=true);await prepare(window.claimData[window.currentClaimId]);window.__claimSaveConfirmed=false;await originalSave();if(!window.__claimSaveConfirmed)return false;show(window.claimData[window.currentClaimId]);return true;}catch(e){notify('Não foi possível salvar a reclamação: '+e.message);return false;}finally{busy=false;controls.forEach(x=>x.disabled=false);}};
window.aesClaimEvidence={calc};
})();
