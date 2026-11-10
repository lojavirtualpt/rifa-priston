// ================= utilidades =================
const CFG = window.RIFA_CONFIG || {};
const ONLINE = !!(CFG.url && CFG.anonKey && window.supabase);
const sb = ONLINE ? window.supabase.createClient(CFG.url, CFG.anonKey) : null;

const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const safeUrl = u => /^(https:\/\/|data:image\/(png|jpe?g|webp);base64,)/i.test(u || '') ? u : '';
const digitos = total => String(total - 1).length;
const fmtNum = (n, total) => String(n).padStart(digitos(total), '0');
const brl = v => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

const SITE_PADRAO = {
  nomeSite: 'Priston Rifas', slogan: 'Itens lendários ao alcance de um número',
  organizador: 'Felipe', certificado: '(preencher)',
  ctaTexto: 'Reservar', entrega: 'O personagem é transferido em até 24h após o resultado, com vídeo da entrega publicado nas nossas redes.',
  corDestaque: '#E2B458', corFundo: '#070C17', corClara: '#F3EEE3', temaPadrao: 'auto', logo: ''
};

// Aplica cores e tema na página
function aplicarTema(site) {
  const r = document.documentElement.style;
  r.setProperty('--ouro', site.corDestaque || SITE_PADRAO.corDestaque);
  r.setProperty('--fundo-escuro', site.corFundo || SITE_PADRAO.corFundo);
  r.setProperty('--fundo-claro', site.corClara || SITE_PADRAO.corClara);
  let t = null; try { t = localStorage.getItem('rifa_tema'); } catch {}
  t = t || (site.temaPadrao !== 'auto' ? site.temaPadrao : null);
  if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
}
function alternarTema() {
  const atual = document.documentElement.dataset.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const novo = atual === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = novo;
  try { localStorage.setItem('rifa_tema', novo); } catch {}
}

// Regra Loteria Federal: últimos N dígitos do 1º prêmio; se não pago, 2º… até 5º
function apurarNumero(total, numeros, premios) {
  const d = digitos(total);
  for (let i = 0; i < premios.length; i++) {
    const p = String(premios[i] || '').replace(/\D/g, '');
    if (!p) continue;
    const n = parseInt(p.slice(-d), 10) % total;
    if (numeros[n] && numeros[n].pago) return { numero: n, premio: i + 1 };
  }
  return null;
}

// ================= mapeamento banco <-> app =================
const deDb = r => r && ({ id: r.id, titulo: r.titulo, descricao: r.descricao, imagem: r.imagem_url, galeria: r.galeria || [],
  valorMercado: +r.valor_mercado, preco: +r.preco, total: r.total, concurso: r.concurso, dataSorteio: r.data_sorteio,
  pacotes: r.pacotes || [], cotas: r.cotas || [], status: r.status, resultado: r.resultado });
const paraDb = c => ({ titulo: c.titulo, descricao: c.descricao, imagem_url: c.imagem, galeria: c.galeria, valor_mercado: c.valorMercado,
  preco: c.preco, total: c.total, concurso: c.concurso, data_sorteio: c.dataSorteio, pacotes: c.pacotes, cotas: c.cotas,
  status: c.status, resultado: c.resultado });

// ================= modo DEMO (localStorage) =================
const DKEY = 'rifa_demo_v2';
const DEMO_PADRAO = {
  site: SITE_PADRAO,
  campanha: { id: 'demo', titulo: 'Knight Lv. 140 — Set +20', descricao: 'Personagem completo, set +20, arma age 18, todas as skills no máximo. Transferência feita na hora após o resultado.',
    imagem: '', galeria: [], valorMercado: 2500, preco: 1.99, total: 1000, concurso: '', dataSorteio: '',
    pacotes: [10, 25, 50, 100], cotas: [{ n: 77, premio: '1kk de gold' }, { n: 333, premio: 'Poção x100' }, { n: 777, premio: 'Arma +10' }],
    status: 'ativa', resultado: null },
  numeros: {}, pedidos: []
};
const dLoad = () => { try { return Object.assign({}, DEMO_PADRAO, JSON.parse(localStorage.getItem(DKEY)) || {}); } catch { return structuredClone(DEMO_PADRAO); } };
const dSave = s => { try { localStorage.setItem(DKEY, JSON.stringify(s)); } catch {} };

// ================= API única usada pelas páginas =================
const api = {
  online: ONLINE,
  async site() {
    if (!ONLINE) return { ...SITE_PADRAO, ...dLoad().site };
    const { data } = await sb.from('site').select('dados').eq('id', 1).maybeSingle();
    return { ...SITE_PADRAO, ...(data?.dados || {}) };
  },
  async campanhas() { // vitrine pública
    if (!ONLINE) { const s = dLoad(); return [{ ...s.campanha, vendidos: Object.keys(s.numeros).length }]; }
    const [{ data, error }, { data: pr }] = await Promise.all([
      sb.from('campanhas').select('*').in('status', ['ativa', 'encerrada']).order('created_at', { ascending: false }),
      sb.rpc('progresso')]);
    if (error) throw error;
    const m = Object.fromEntries((pr || []).map(r => [r.campanha_id, +r.vendidos]));
    return data.map(r => ({ ...deDb(r), vendidos: m[r.id] || 0 }));
  },
  async campanha(id) {
    if (!ONLINE) return dLoad().campanha;
    const { data, error } = await sb.from('campanhas').select('*').eq('id', id).maybeSingle();
    if (error) throw error; return deDb(data);
  },
  async meusTodos(whats) {
    whats = whats.replace(/\D/g, '');
    if (ONLINE) { const { data, error } = await sb.rpc('meus_todos', { p_whats: whats }); if (error) throw error;
      return data.map(r => ({ campanha: { id: r.campanha_id, titulo: r.titulo, imagem: r.imagem, total: r.total, status: r.status_campanha, resultado: r.resultado }, id: r.pedido, status: r.status, numeros: r.numeros, valor: +r.valor, created_at: r.created_at })); }
    const s = dLoad(); return s.pedidos.filter(p => p.whats === whats && p.status !== 'expirado').map(p => ({ ...p, campanha: s.campanha }));
  },
  async listarCampanhas() { // admin: inclui rascunhos
    if (!ONLINE) return [dLoad().campanha];
    const { data, error } = await sb.from('campanhas').select('*').order('created_at', { ascending: false });
    if (error) throw error; return data.map(deDb);
  },
  async numeros(c) {
    if (!ONLINE) return dLoad().numeros;
    const map = {}; let de = 0;
    while (true) {
      const { data, error } = await sb.from('numeros').select('numero,pago').eq('campanha_id', c.id).range(de, de + 999);
      if (error) throw error; data.forEach(r => map[r.numero] = { pago: r.pago });
      if (data.length < 1000) break; de += 1000;
    }
    return map;
  },
  async reservar(c, qtd, nome, whats) {
    if (ONLINE) { const { data, error } = await sb.rpc('reservar', { p_campanha: c.id, p_qtd: qtd, p_nome: nome, p_whats: whats }); if (error) throw new Error(error.message); return data; }
    const s = dLoad(); const livres = [];
    for (let i = 0; i < s.campanha.total; i++) if (!s.numeros[i]) livres.push(i);
    if (livres.length < qtd) throw new Error('Números insuficientes');
    const nums = []; for (let i = 0; i < qtd; i++) nums.push(livres.splice(Math.floor(Math.random() * livres.length), 1)[0]);
    const id = Date.now().toString(36).toUpperCase();
    nums.forEach(n => s.numeros[n] = { pago: false, pedido: id });
    s.pedidos.push({ id, nome: nome.slice(0, 40), whats: whats.replace(/\D/g, ''), numeros: nums, valor: qtd * s.campanha.preco, status: 'aguardando', created_at: new Date().toISOString() });
    dSave(s); return { pedido: id, numeros: nums, valor: qtd * s.campanha.preco };
  },
  async meus(c, whats) {
    whats = whats.replace(/\D/g, '');
    if (ONLINE) { const { data, error } = await sb.rpc('meus_numeros', { p_campanha: c.id, p_whats: whats }); if (error) throw error; return data; }
    return dLoad().pedidos.filter(p => p.whats === whats && p.status !== 'expirado');
  },
  async ranking(c) {
    if (ONLINE) { const { data } = await sb.rpc('ranking', { p_campanha: c.id }); return data || []; }
    const rk = {}; dLoad().pedidos.filter(p => p.status === 'pago').forEach(p => { const k = p.nome.split(' ')[0]; rk[k] = (rk[k] || 0) + p.numeros.length; });
    return Object.entries(rk).map(([nome, qtd]) => ({ nome, qtd })).sort((a, b) => b.qtd - a.qtd).slice(0, 3);
  },
  // só existe no modo demo — em produção quem confirma é o webhook do Pix
  pagarDemo(id) { const s = dLoad(); const p = s.pedidos.find(x => x.id === id); if (!p) return; p.status = 'pago'; p.numeros.forEach(n => s.numeros[n].pago = true); dSave(s); },

  // ---------- ADMIN ----------
  auth: {
    async sessao() { if (!ONLINE) return { demo: true }; const { data } = await sb.auth.getSession(); return data.session; },
    async entrar(email, senha) { const { error } = await sb.auth.signInWithPassword({ email, password: senha }); if (error) throw new Error('E-mail ou senha incorretos'); },
    async sair() { if (ONLINE) await sb.auth.signOut(); },
    async nivel() { const { data } = await sb.auth.mfa.getAuthenticatorAssuranceLevel(); return data; },
    async fatores() { const { data } = await sb.auth.mfa.listFactors(); return data?.totp || []; },
    async cadastrar2fa() { const { data, error } = await sb.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Rifa ' + Date.now() }); if (error) throw error; return data; },
    async verificar2fa(factorId, code) {
      const { data: ch, error: e1 } = await sb.auth.mfa.challenge({ factorId }); if (e1) throw e1;
      const { error } = await sb.auth.mfa.verify({ factorId, challengeId: ch.id, code }); if (error) throw new Error('Código inválido');
    },
    async ehAdmin() { if (!ONLINE) return true; const { data } = await sb.rpc('is_admin'); return !!data; }
  },
  async adminCampanha(id) {
    if (!ONLINE) return dLoad().campanha;
    let q = sb.from('campanhas').select('*');
    q = id ? q.eq('id', id) : q.order('created_at', { ascending: false }).limit(1);
    const { data } = await q.maybeSingle();
    return deDb(data);
  },
  async salvarCampanha(c) {
    if (!ONLINE) { const s = dLoad(); s.campanha = { ...s.campanha, ...c }; dSave(s); return s.campanha; }
    const q = c.id ? sb.from('campanhas').update(paraDb(c)).eq('id', c.id) : sb.from('campanhas').insert(paraDb(c));
    const { data, error } = await q.select().single(); if (error) throw new Error(error.message); return deDb(data);
  },
  async salvarSite(site) {
    if (!ONLINE) { const s = dLoad(); s.site = site; dSave(s); return; }
    const { error } = await sb.from('site').update({ dados: site }).eq('id', 1); if (error) throw new Error(error.message);
  },
  async subirImagem(file) {
    if (!/^image\/(png|jpeg|webp)$/.test(file.type)) throw new Error('Use PNG, JPG ou WEBP');
    if (file.size > 5 * 1024 * 1024) throw new Error('Máximo 5 MB');
    if (!ONLINE) return await new Promise(r => { const fr = new FileReader(); fr.onload = () => r(fr.result); fr.readAsDataURL(file); });
    const nome = crypto.randomUUID() + '.' + file.type.split('/')[1];
    const { error } = await sb.storage.from('personagens').upload(nome, file, { contentType: file.type });
    if (error) throw new Error(error.message);
    return sb.storage.from('personagens').getPublicUrl(nome).data.publicUrl;
  },
  async pedidos(c) {
    if (!ONLINE) return dLoad().pedidos.slice().reverse();
    const { data, error } = await sb.from('pedidos').select('*').eq('campanha_id', c.id).order('created_at', { ascending: false }).limit(500);
    if (error) throw error; return data;
  },
  async confirmar(id) {
    if (!ONLINE) return api.pagarDemo(id);
    const { error } = await sb.rpc('confirmar_pedido', { p_pedido: id }); if (error) throw new Error(error.message);
  },
  async zerarDemo() { if (!ONLINE) { const s = dLoad(); s.numeros = {}; s.pedidos = []; s.campanha.resultado = null; dSave(s); } }
};
