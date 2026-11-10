// Função "pagamento" (Supabase Edge Function) — integra com o Checkout da InfinitePay.
//  POST ?acao=criar   { pedido }                      -> gera/reaproveita o link de pagamento
//  POST (webhook/retorno) { order_nsu, transaction_nsu, invoice_slug|slug, receipt_url }
//      -> confere na InfinitePay (payment_check) e só então marca como pago.
// Segredos (Edge Functions > Secrets): INFINITEPAY_HANDLE (sua InfiniteTag sem $), SITE_URL (opcional).
// Em Settings da função: desligar "Verify JWT" (a InfinitePay não envia token).
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const HANDLE = (Deno.env.get("INFINITEPAY_HANDLE") ?? "").replace(/^\$/, "");
const SITE = Deno.env.get("SITE_URL") ?? "https://lojavirtualpt.github.io/rifa-priston/";
const BASE = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(BASE, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const API = "https://api.checkout.infinitepay.io";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "método não permitido" }, 405);
  if (!HANDLE) return json({ error: "INFINITEPAY_HANDLE não configurado" }, 500);
  const body = await req.json().catch(() => ({}));
  const acao = new URL(req.url).searchParams.get("acao");
  try {
    return acao === "criar" ? await criar(body) : await confirmar(body);
  } catch (e) {
    console.error("erro", e);
    return json({ error: "erro interno" }, 500);
  }
});

async function criar({ pedido }: { pedido?: string }) {
  if (!pedido || !UUID.test(pedido)) return json({ error: "Pedido inválido" }, 400);
  const { data: p } = await sb.from("pedidos")
    .select("id,valor,status,numeros,checkout_url,expira_em,campanhas(titulo)")
    .eq("id", pedido).single();
  if (!p || p.status !== "aguardando" || new Date(p.expira_em) < new Date())
    return json({ error: "Reserva expirada ou indisponível" }, 400);
  if (p.checkout_url) return json({ url: p.checkout_url });

  const cents = Math.round(Number(p.valor) * 100);
  if (cents < 100) return json({ error: "O valor mínimo de pagamento é R$ 1,00" }, 400);
  // deno-lint-ignore no-explicit-any
  const titulo = (p as any).campanhas?.titulo ?? "Rifa";
  const r = await fetch(`${API}/links`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      handle: HANDLE,
      order_nsu: p.id,
      items: [{ quantity: 1, price: cents, description: `${titulo} - ${p.numeros.length} número(s)`.slice(0, 120) }],
      redirect_url: `${SITE}minha-conta.html`,
      webhook_url: `${BASE}/functions/v1/pagamento`,
    }),
  });
  const d = await r.json().catch(() => ({}));
  const url = d.url ?? d.link ?? d.checkout_url ?? d.payment_url;
  if (!r.ok || !url) {
    console.error("infinitepay links", r.status, JSON.stringify(d));
    return json({ error: "Não foi possível gerar o pagamento agora" }, 502);
  }
  await sb.from("pedidos").update({ checkout_url: url }).eq("id", p.id);
  return json({ url });
}

// deno-lint-ignore no-explicit-any
async function confirmar(b: any) {
  const order_nsu = String(b.order_nsu ?? "");
  const tx = String(b.transaction_nsu ?? "");
  const slug = String(b.invoice_slug ?? b.slug ?? "");
  if (!UUID.test(order_nsu) || !tx || !slug) return json({ ok: false, error: "dados incompletos" }, 400);

  const r = await fetch(`${API}/payment_check`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ handle: HANDLE, order_nsu, transaction_nsu: tx, slug }),
  });
  const c = await r.json().catch(() => ({}));
  if (!c.success || !c.paid) return json({ ok: true, pago: false });

  const { data: p } = await sb.from("pedidos").select("valor").eq("id", order_nsu).single();
  if (!p) return json({ ok: false, error: "pedido não encontrado" }, 400);
  if (Number(c.amount) < Math.round(Number(p.valor) * 100)) {
    console.error("valor divergente", order_nsu, c.amount, p.valor);
    return json({ ok: false, error: "valor divergente" }, 400);
  }
  const { data, error } = await sb.rpc("registrar_pagamento", {
    p_pedido: order_nsu, p_tx: tx, p_receipt: b.receipt_url ?? null, p_metodo: c.capture_method ?? null,
  });
  if (error) { console.error(error); return json({ ok: false }, 500); }
  return json({ ok: true, pago: data === "pago", status: data });
}
