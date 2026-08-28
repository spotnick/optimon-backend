# Relatório Final — Fase 2.5.3 (Correção Definitiva: Usuários Auth × public.usuarios)

Status geral: **CONCLUÍDA no código, nos testes e na documentação, com uma limitação de ambiente declarada** (item 11). `tests/run_tests_fase253.sh`: **16 PASS / 0 FAIL / 0 SKIP**, precedido por PASSO-0 = regressão completa herdada via `run_tests_fase251.sh` (que por sua vez encadeia Fase 1 → 2.5.1): **26 PASS / 0 FAIL / 7 SKIP, 0 regressão**. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado, nenhuma tabela duplicada, nenhuma policy de RLS nova/enfraquecida — apenas **1 migration nova, aditiva** (`20260921090000`, só estende a whitelist de auditoria já existente). Build do frontend (`npm run build`) passa sem erro.

Relato original do usuário: administrador cria um usuário → a identidade aparece em Supabase Authentication → Users → o cadastro **nunca** aparece em OptiMon → Usuários → uma nova tentativa com o mesmo e-mail sempre responde "A user with this email address has already been registered", sem nenhum caminho de recuperação.

## 1. Diagnóstico da causa raiz (evidência real, não assumida)

Antes de tocar em qualquer código, o INSERT real de `completeProfile()` (`api/routes/users.js`) foi reproduzido direto contra o schema Postgres deste ambiente, exatamente como o formulário "+ Novo Usuário" o produz quando o campo CPF é deixado em branco:

```sql
insert into public.usuarios (id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes)
values ('<uuid>', 'Diagnostico Teste', 'diagnostico.cpf.vazio@teste.com', '', '', '', '', 'COMERCIAL', '');
-- ERROR:  new row for relation "usuarios" violates check constraint "usuarios_cpf_formato"
```

Confirmado: **causa raiz = `cpf ?? null` não trata string vazia.** O operador de coalescência nula (`??`) só substitui `null`/`undefined` por `null` — nunca substitui `''`. O formulário React (`web/src/pages/Users.jsx`, `emptyForm()`) inicializa CPF (e os demais campos opcionais) como `''`, o comportamento padrão de um `<input>` controlado deixado em branco — e CPF é um campo **opcional** na tela, então esse é o caminho comum, não um caso extremo. `public.usuarios` tem, desde a Fase 2.5 (`20260913090000_phase_2_5_01_usuarios_perfil_estendido.sql`), `constraint usuarios_cpf_formato check (cpf is null or cpf ~ '^[0-9]{11}$')` — `''` não é `null` nem casa com o regex, então o INSERT sempre falhava.

Repetido o mesmo INSERT com `cpf = null` (o que a correção abaixo agora produz) — sucesso confirmado, sem nenhum erro. RLS foi verificada separadamente (item 9) como não sendo a causa.

**Por que isso deixava um usuário órfão, e não só um erro visível:** no momento em que `completeProfile()` roda, `adminAuth().inviteUserByEmail()` já tinha sido chamado com sucesso — a identidade em `auth.users` já existe e o e-mail de convite real já foi enviado. Antes desta fase, essa falha de INSERT respondia `207 Multi-Status`, que a correção da Fase 2.5.1 (`web/src/lib/api.js`) já passou a tratar como erro no frontend — mas o backend nunca desfazia a identidade Auth criada, então ela ficava permanentemente órfã (existe em Auth, nunca em Usuários), e qualquer nova tentativa com o mesmo e-mail batia em "already been registered" no próprio Supabase, sem nenhuma saída — reproduzindo exatamente o relato do usuário.

## 2. Correção da causa raiz

`emptyToNull(value)`, nova em `api/routes/users.js`, normaliza qualquer string vazia ou só-espaços para `null` antes do INSERT — aplicada a todos os campos de texto opcionais (`telefone`, `cpf`, `cargo`, `departamento`, `observacoes`) em `completeProfile()`, usada tanto por `POST /invite` quanto por `POST /reconcile` (item 5). Confirmado por teste direto contra o schema real (`tests/run_tests_fase253.sh`, TESTE-01/02): o INSERT que antes violava `usuarios_cpf_formato` com `cpf=''` agora funciona com `cpf=null`.

## 3. Redesenho do fluxo de convite: idempotência (Estados A/B/C/D)

Consertar a causa raiz específica não fecha a classe do problema — qualquer outra falha transitória no INSERT reproduziria o mesmo sintoma. `POST /api/users/invite` agora verifica o estado do e-mail **antes** de chamar a Auth Admin API, cruzando `public.usuarios` (perfil) com `auth.users` (identidade, via `findAuthUserByEmail()`, paginado):

| Estado | Auth existe? | Perfil existe? | Comportamento |
|---|---|---|---|
| A | não | não | caminho normal — cria os dois |
| B | sim | sim | `409`, nunca recria |
| C | sim | não | `409`, orienta `POST /api/users/reconcile` — **nunca** reconvida (falharia "already registered") |
| D | não | sim | `409`, inconsistência crítica, bloqueia criação automática (não deveria acontecer sob a REGRA 1:1, mas o código verifica em vez de assumir) |

Nenhum desses estados tenta gerar um UUID próprio para `public.usuarios` — o `id` sempre vem de `auth.users`, nunca é inventado pelo Node/Postgres, mantendo a REGRA 1:1 do sistema.

## 4. Rollback controlado (evitar usuário órfão)

No Estado A, se `completeProfile()` falhar depois da identidade Auth já ter sido criada **nesta mesma operação**, a rota tenta reverter: `adminAuth().deleteUser(authUser.id)`. A salvaguarda central: isso só pode atingir o `id` recém-criado nesta chamada — o código nunca tenta apagar uma identidade Auth pré-existente, porque nunca tem como saber se ela veio de outra fonte legítima. Se o rollback funciona, o e-mail volta a ficar livre e a resposta (`400`) diz isso explicitamente; se falha, a resposta (`500`) também diz isso explicitamente e aponta para `GET /api/users/health`/`POST /api/users/reconcile` — nunca mais um `207` de "sucesso parcial" ambíguo (removido de `api/routes/users.js`; confirmado por `grep`, TESTE-08).

O erro real do Postgres/PostgREST (`code`/`message`/`details`/`hint`) é registrado sem máscara no log estruturado do backend, sob a tag `[USER_INVITE_PROFILE]` — nunca senha, token, `service_role_key` ou qualquer credencial.

## 5. Novos endpoints: `POST /api/users/reconcile` e `GET /api/users/health`

- **`POST /api/users/reconcile`** — caminho de recuperação do Estado C. Recebe os mesmos dados cadastrais do convite original e completa `public.usuarios` usando o `id` que a identidade Auth já tem — nunca cria uma identidade nova, nunca reenvia e-mail. Recusa (`409`) se o e-mail já tiver cadastro completo (Estado B); recusa (`404`) se não existir nenhuma identidade Auth para reconciliar. Só ADMINISTRADOR; `501 SERVICE_ROLE_NAO_CONFIGURADO` controlado sem a Auth Admin API.
- **`GET /api/users/health`** — só leitura, nunca altera nada. Compara `auth.users` × `public.usuarios` (paginado, já que a Auth Admin API não tem um diff nativo) e devolve `identidades_auth_orfas` (Estado C), `perfis_sem_auth` (Estado D) e `integro` — `true`/`false` quando a comparação é possível, **`null`** (nunca uma adivinhação) quando a Auth Admin API não está configurada no ambiente.

## 6. `GET /api/users?include_orphans=true`

Quando pedido por um ADMINISTRADOR com a Auth Admin API disponível, acrescenta linhas sintéticas para identidades Auth órfãs (Estado C) na própria listagem — `id: null`, `auth_user_id` presente, `status_auth: 'ORFAO_SEM_PERFIL'` — para que o painel de Usuários mostre o problema onde o administrador já está olhando, sem precisar ir a `/usuarios/saude` primeiro.

## 7. Frontend: recuperação de perfil, indicador de integridade e `/usuarios/saude`

`web/src/pages/Users.jsx`: a tela nunca mais mostra "Usuário criado"/"Convite enviado" quando só a identidade Auth foi criada — só chega lá quando o backend responde `201` de verdade (as duas etapas completas). Ao receber `409` com `state: 'C_AUTH_ORFAO'`, mostra um botão "Recuperar Perfil" que reabre o formulário em modo de recuperação (e-mail travado) e envia para `POST /api/users/reconcile` em vez de `/invite`. A listagem (quando ADMINISTRADOR) pede `?include_orphans=true` e cada linha órfã ganha seu próprio botão "Recuperar Perfil". Um badge de integridade no cabeçalho (alimentado por `GET /api/users/health`) linka para a nova página `web/src/pages/UsersHealth.jsx` (rota `/usuarios/saude`), que lista os dois estados de inconsistência em detalhe.

## 8. Auditoria: 7 ações semânticas novas

Migration `20260921090000_phase_2_5_3_01_auditoria_usuarios_estendida.sql` — mesma tabela (`public.auditoria`) e mesma função (`app.registrar_auditoria_semantica`) desde a Fase 2.3.1, sem tabela nem função paralela. Estende a `CHECK` constraint e a whitelist interna juntas, preservando 100% das ações já existentes: `USER_INVITE_STARTED`, `USER_AUTH_CREATED`, `USER_PROFILE_CREATED`, `USER_INVITE_COMPLETED`, `USER_AUTH_ROLLBACK`, `USER_AUTH_ORPHAN`, `USER_PROFILE_RECONCILED`. Confirmado por teste direto (TESTE-09): as 7 ações novas e todas as ações de usuário já existentes continuam aceitas.

## 9. RLS/RBAC — verificado, não alterado

A hipótese de RLS estar bloqueando o INSERT foi verificada e descartada com evidência, não por leitura de código: simulando `set local role authenticated; set local request.jwt.claims = '{"sub":"<admin>"}'`, um ADMINISTRADOR real conseguiu inserir um perfil novo em `public.usuarios` usando exclusivamente a policy `usuarios_admin_all` já existente desde a Fase 1 (`app.tem_perfil('ADMINISTRADOR')`, `for all to authenticated`) — sem nenhuma alteração. Confirmado também que `public.usuarios` continua com exatamente 2 policies (`usuarios_select`, `usuarios_admin_all`); nenhuma nova foi criada, nenhuma usa `USING (true)` para escrita, nenhuma RLS foi desabilitada (TESTE-03/03b).

## 10. Testes

`tests/run_tests_fase253.sh`, 10 testes, **16 PASS / 0 FAIL / 0 SKIP**:

1. **TESTE-01/02** — causa raiz reproduzida e conserto confirmado direto contra o Postgres real (item 1/2 acima).
2. **TESTE-03/03b** — RLS/RBAC intactos (item 9 acima).
3. **TESTE-04** — e-mail já cadastrado nunca gera duplicata nem 500; sempre `409` com `state`.
4. **TESTE-05** — `/reconcile` bloqueado para não-ADMINISTRADOR (403) e controlado sem Auth Admin API (501).
5. **TESTE-06** — `/health` bloqueado para não-ADMINISTRADOR (403) e responde 200 com o formato esperado para ADMINISTRADOR.
6. **TESTE-07** — `?include_orphans=true` nunca crasha.
7. **TESTE-08** — regressão: `res.status(207)` não existe mais em `api/routes/users.js`.
8. **TESTE-09** — auditoria aceita as 7 ações novas + todas as antigas (item 8 acima).
9. **TESTE-10** — nenhum secret/JWT completo nos logs desta execução.

**Bug real encontrado pelos próprios testes desta fase (não por inspeção de código):** `GET /api/users/health`, registrada depois de `GET /api/users/:id`, nunca era alcançada — o Express casa rotas na ordem de registro, então `/health` batia em `:id` primeiro (`id="health"`) e o Postgres rejeitava com `invalid input syntax for type uuid: "health"` (409). Corrigido movendo `GET /health` para antes de `GET /:id`, com um comentário no código para o mesmo cuidado valer em qualquer rota GET de segmento fixo futura sob `/api/users`.

## 11. Limitações declaradas do ambiente e roteiro de E2E manual

Mesma categoria de limitação já documentada desde a Fase 2.5/2.5.1 (Storage, Auth Admin API): este harness local não tem um GoTrue (Supabase Auth) real, então `SUPABASE_SERVICE_ROLE_KEY` nunca está configurada aqui, e os Estados A/B/C (que dependem de `auth.users` existir de verdade) não puderam ser exercitados ponta-a-ponta por HTTP neste sandbox — só o Estado D, que não depende de Auth, foi validado por HTTP de ponta a ponta (TESTE-04). **Um teste E2E real contra `https://optimon.com.br` não foi executado nesta sessão** — exige autenticar como ADMINISTRADOR num projeto Supabase de produção, algo que este ambiente não tem credenciais para fazer e que, por política, nunca deveria fazer em nome do usuário sem supervisão direta. Roteiro para o usuário (ou alguém da equipe) executar manualmente:

1. Login em `https://optimon.com.br` como ADMINISTRADOR.
2. Em Usuários, criar um usuário novo **deixando CPF em branco** — antes desta fase, isso reproduzia o bug relatado; espera-se agora `201` com o cadastro completo aparecendo na lista.
3. Repetir a criação com o **mesmo e-mail** — espera-se `409` com uma mensagem clara (Estado B), nunca "already registered" sem saída.
4. Abrir `/usuarios/saude` — espera-se `integro: true` (ou a lista de inconsistências, se alguma identidade órfã de antes desta correção ainda existir — nesse caso, usar "Recuperar Perfil" a partir da lista de Usuários ou da própria tela de saúde).
5. Se alguma identidade órfã pré-existente aparecer no passo 4 (criada antes desta correção, quando o bug do CPF ainda existia), usar "Recuperar Perfil" com o e-mail correspondente — espera-se `201` e o desaparecimento da inconsistência na releitura de `/usuarios/saude`.

Nada nesta fase alterou o procedimento de deploy já documentado (Railway/Vercel/Supabase) além da nova migration (`20260921090000`, aplicada como qualquer outra) — nenhuma variável de ambiente nova foi introduzida.
