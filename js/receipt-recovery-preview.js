(function(){
function showRecovery(){
 const keys=[];
 for(let i=0;i<localStorage.length;i++){
   const key=localStorage.key(i);
   if(/financ|receb|receipt|payment|aurea|aes/i.test(key))keys.push(key);
 }
 const message=keys.length?'Possíveis dados preservados neste navegador:\n'+keys.join('\n'):'Nenhuma chave financeira identificada neste navegador.';
 alert(message+'\n\nNenhum dado foi alterado. Envie os nomes das chaves para análise.');
}
function mount(){
 if(document.getElementById('aesRecoverReceipt'))return;
 const parent=document.getElementById('financeOrderWorkspace');
 if(!parent)return;
 const button=document.createElement('button');
 button.type='button';button.id='aesRecoverReceipt';button.className='btn';
 button.textContent='Recuperar recebimentos anteriores';
 button.onclick=showRecovery;
 parent.prepend(button);
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount);else mount();
})();