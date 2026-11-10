# Como deixar o painel blindado (passo a passo)

O site em si (HTML) fica público no GitHub Pages — isso é normal e seguro. Quem protege os dados é o **banco (Supabase)**: ele só aceita alterações de quem estiver logado **com senha + código do celular (2FA)** e cadastrado como admin. Mesmo que alguém copie o site inteiro, não consegue alterar nada.

## O que já está implementado
| Proteção | Como funciona |
|---|---|
| Login com e-mail e senha | Supabase Auth; 5 tentativas erradas → bloqueio de 1 min |
| **2FA obrigatório** | App autenticador (Google Authenticator/Authy). Sem o código, o banco recusa qualquer escrita |
| Lista de admins | Só usuários na tabela `admins` alteram algo |
| Regras no banco (RLS) | Visitante só lê campanha e mapa de números; não lê nomes/telefones de ninguém |
| Reserva só por função | Visitante não grava direto: a função `reservar` valida tudo, limita 500 números e 3 reservas pendentes por telefone |
| Confirmação de pagamento | Só admin (ou o webhook do Pix com chave secreta no servidor) |
| Fotos | Só admin envia; PNG/JPG/WEBP até 5 MB |
| Anti-injeção (XSS) | Todo texto exibido é escapado; CSP bloqueia scripts de terceiros |
| Auditoria | Toda alteração da campanha fica registrada com usuário e horário |
| Sessão | Sai sozinho após 30 min parado; painel não aparece no Google (`noindex`) |

## Configurar (uns 20 min)
1. Crie uma conta em **supabase.com** → *New project* (plano grátis).
2. **SQL Editor** → cole o conteúdo de `supabase/schema.sql` → *Run*.
3. **Authentication → Providers → Email**: deixe ativo e **desligue "Allow new users to sign up"** (ninguém consegue se cadastrar).
4. **Authentication → Users → Add user**: crie o seu usuário com senha forte (16+ caracteres, use gerenciador de senhas).
5. **Authentication → Multi-Factor**: confirme que TOTP está habilitado.
6. Volte ao SQL Editor e rode (com seu e-mail):
   `insert into public.admins(user_id) select id from auth.users where email = 'SEU_EMAIL';`
7. **Project Settings → API**: copie *Project URL* e *anon public key* para o `config.js`.
   ⚠ **Nunca** use a *service_role key* no site.
8. **Authentication → URL Configuration**: em *Site URL* coloque o endereço do GitHub Pages.
9. Abra `admin.html`, entre, escaneie o QR code no app autenticador e pronto.

## Cuidados seus (fazem diferença)
- Ative 2FA também no **GitHub**, no **Supabase** e no e-mail usado no login.
- Repositório no GitHub: ninguém além de você com permissão de escrita.
- Guarde os códigos de recuperação do autenticador.
- Pix: use Mercado Pago / Asaas / Efí com **webhook** numa *Edge Function* do Supabase — a chave do gateway fica só no servidor, nunca no `config.js`.
