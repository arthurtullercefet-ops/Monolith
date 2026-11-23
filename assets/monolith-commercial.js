(function(root,factory){
  const api=factory();
  if(typeof module==='object' && module.exports) module.exports=api;
  if(root) root.MonolithCommercial=api;
})(typeof window==='undefined'?null:window,function(){
  'use strict';
  const words={
    pt:{loading:'Confirmando plano e vagas…',error:'Não foi possível confirmar o plano. Atualize a página para tentar novamente.',included:'Incluído',student:'O acesso ao acompanhamento e a busca de profissionais estão incluídos. O serviço do personal é contratado separadamente.',legacy:'Acesso existente preservado',beta:'Acesso beta',subscription:'Assinatura ativa',demo:'Demonstração',none:'Assinatura necessária para ativar alunos',limit:'alunos ativos',over:'Limite excedido: o histórico permanece disponível; novas ativações estão bloqueadas.',full:'Limite de alunos ativos atingido.',basic:'Personal Basic',pro:'Personal Pro',catalog:'Preços de lançamento',plan:'Plano',market:'Mercado',price:'Mensalidade',seats:'Alunos ativos',US:'EUA',BR:'Brasil',checkout:'Contratação ainda não disponível. A conexão de pagamentos está em preparação.',policy:'Acesso do aluno incluído. Busca de profissionais gratuita.',commission:'Novas parcerias: 15% de comissão recorrente sobre receita elegível. Acordos individuais são preservados.',core:'Basic e Pro incluem as mesmas ferramentas centrais. Alunos com acesso e alunos gerenciados ocupam uma vaga cada.'},
    en:{loading:'Confirming plan and seats…',error:'Could not confirm your plan. Refresh the page to try again.',included:'Included',student:'Access to coaching and professional discovery are included. The trainer’s service is contracted separately.',legacy:'Existing access preserved',beta:'Beta access',subscription:'Active subscription',demo:'Demo',none:'Subscription required to activate clients',limit:'active clients',over:'Limit exceeded: history remains available; new activations are blocked.',full:'Active client limit reached.',basic:'Personal Basic',pro:'Personal Pro',catalog:'Launch prices',plan:'Plan',market:'Market',price:'Monthly price',seats:'Active clients',US:'US',BR:'Brazil',checkout:'Subscriptions are not available yet. Payment setup is in progress.',policy:'Client access included. Professional discovery is free.',commission:'New partnerships: 15% recurring commission on eligible revenue. Individual agreements are preserved.',core:'Basic and Pro include the same core tools. App users and managed clients each occupy one seat.'},
    es:{loading:'Confirmando plan y plazas…',error:'No se pudo confirmar el plan. Actualiza la página para volver a intentarlo.',included:'Incluido',student:'El acceso al seguimiento y la búsqueda de profesionales están incluidos. El servicio del entrenador se contrata por separado.',legacy:'Acceso existente conservado',beta:'Acceso beta',subscription:'Suscripción activa',demo:'Demostración',none:'Se necesita una suscripción para activar alumnos',limit:'alumnos activos',over:'Límite superado: el historial sigue disponible; las nuevas activaciones están bloqueadas.',full:'Límite de alumnos activos alcanzado.',basic:'Personal Basic',pro:'Personal Pro',catalog:'Precios de lanzamiento',plan:'Plan',market:'Mercado',price:'Mensualidad',seats:'Alumnos activos',US:'EE. UU.',BR:'Brasil',checkout:'Las suscripciones aún no están disponibles. La conexión de pagos está en preparación.',policy:'Acceso del alumno incluido. Búsqueda de profesionales gratuita.',commission:'Nuevas alianzas: 15% de comisión recurrente sobre ingresos elegibles. Se conservan los acuerdos individuales.',core:'Basic y Pro incluyen las mismas herramientas principales. Los alumnos con acceso y los gestionados ocupan una plaza cada uno.'}
  };
  const locales={pt:'pt-BR',en:'en-US',es:'es-419'};
  const dictionary=lang=>words[lang]||words.pt;
  const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  function validState(s){
    return s && typeof s.is_trainer==='boolean' && Number.isSafeInteger(s.student_limit) && s.student_limit>=0
      && Number.isSafeInteger(s.active_students) && s.active_students>=0;
  }
  function formatPrice(price,language='pt'){
    if(!price || !['USD','BRL'].includes(price.currency) || !Number.isSafeInteger(price.monthly_price_minor) || price.monthly_price_minor<0) throw new Error('Invalid price');
    const formatted=new Intl.NumberFormat(locales[language]||locales.pt,{style:'currency',currency:price.currency}).format(price.monthly_price_minor/100);
    return price.currency==='USD' && language!=='en' ? formatted.replace(/^\$/, 'US$') : formatted;
  }
  function capacityView(state,status='loaded',language='pt'){
    const w=dictionary(language);
    if(status==='loading' || status==='idle') return {badge:'—',detail:w.loading,canAdd:false};
    if(!['loaded','demo'].includes(status) || !validState(state)) return {badge:'—',detail:w.error,canAdd:false};
    if(!state.is_trainer) return {badge:w.included,detail:w.student,canAdd:false};
    const name=status==='demo'?w.demo:state.source==='legacy'?w.legacy:state.source==='beta'?w.beta:state.source==='subscription'?(state.plan_key==='trainer_pro'?w.pro:w.basic):w.none;
    const detail=state.student_limit===0?w.none+(state.active_students>0?' '+w.over:''):state.active_students>state.student_limit?w.over:state.active_students===state.student_limit?w.full:name+' · '+state.student_limit+' '+w.limit;
    return {badge:state.active_students+'/'+state.student_limit,detail,canAdd:state.can_add_student===true && state.active_students<state.student_limit};
  }
  function settingsHTML(state,{status='loaded',language='pt'}={}){
    const w=dictionary(language),view=capacityView(state,status,language);
    if(!['loaded','demo'].includes(status) || !validState(state)) return '<p role="status">'+escape(view.detail)+'</p>';
    if(!state.is_trainer) return '<p>'+escape(w.student)+'</p>';
    const rows=(Array.isArray(state.prices)?state.prices:[]).filter(pr=>['US','BR'].includes(pr.market) && ['trainer_basic','trainer_pro'].includes(pr.plan_key));
    let html='<p><strong>'+escape(view.badge)+'</strong> · '+escape(view.detail)+'</p><p>'+escape(w.policy)+'</p>';
    if(rows.length){
      html+='<h4>'+escape(w.catalog)+'</h4><div style="overflow-x:auto"><table style="width:100%;text-align:left"><thead><tr>'+[w.plan,w.market,w.price,w.seats].map(x=>'<th>'+escape(x)+'</th>').join('')+'</tr></thead><tbody>';
      for(const pr of rows){
        let price; try{price=formatPrice(pr,language);}catch{continue;}
        if(!Number.isSafeInteger(pr.student_limit) || pr.student_limit<0) continue;
        html+='<tr>'+[pr.name,w[pr.market],price,pr.student_limit].map(x=>'<td style="padding:8px 6px">'+escape(x)+'</td>').join('')+'</tr>';
      }
      html+='</tbody></table></div><p>'+escape(w.core)+'</p>';
    }
    return html+'<p>'+escape(w.checkout)+'</p><p>'+escape(w.commission)+'</p>';
  }
  return Object.freeze({formatPrice,capacityView,settingsHTML});
});

