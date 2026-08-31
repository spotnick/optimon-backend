#!/usr/bin/env bash
# OptiMon — Fase 3.9: revisão das cláusulas contratuais + modelo de cessão de uso.
#
# Cobre a "REGRA CRÍTICA" (seção 30 do prompt do usuário): as cláusulas não podem ser
# apenas exibição de front-end — precisam ser genuinamente usadas pelos geradores de
# PDF/DOCX, e um contrato aprovado precisa GERAR, de fato, marcadores para: prazo 48
# meses, recurso PON/fibra, mínimo mensal, variável, take-or-pay (monetário e em
# clientes), rampa, reajuste, clientes reservados, restrição de rede concorrente,
# restrição de atendimento à Prefeitura, responsabilidade do parceiro pelo cliente final,
# propriedade dos ativos, devolução dos ativos, regras de rescisão, venda/transferência da
# operação, direito da NICK sobre seus recursos (não-exclusividade), ausência de
# sociedade, e assinatura das partes.
#
# Mesma disciplina das baterias anteriores (fase11/fase12/fase2/fase38): nenhum teste foi
# escrito sem antes checar o schema/código real (ver migration 20260930090000 e a
# reescrita de api/lib/contractDocumentModel.js desta mesma sessão). Passo 0 é o replay
# completo do zero de TODAS as migrations (inclusive a nova) — nunca presumido só porque
# "a migration não deu erro na minha máquina uma vez".
#
# ESCOPO DELIBERADAMENTE FORA DESTA BATERIA (nenhuma tentativa de fingir cobertura): as 2
# rotas HTTP novas (PATCH /:id/pricing-config, PATCH /:id/rescisao-config) não são
# testadas aqui via curl — este sandbox não tem o servidor Express + PostgREST rodando
# contra este Postgres local (só psql direto). Essas rotas foram inspecionadas por
# leitura de código (mesmo padrão upsert+whitelist de PATCH /:id/regras, já testado via
# HTTP em baterias anteriores) mas NÃO têm evidência de execução HTTP real nesta bateria
# — não declarar PASS para elas a partir deste arquivo.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0
FAIL=0
FAILED_NAMES=()
pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "FAIL | $1"; echo "  -> $2"; }

export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"

as_role() {
  local uid="$1"; local sql="$2"
  $PSQL -v ON_ERROR_STOP=0 -c "
begin;
set local role authenticated;
set local request.jwt.claims = '{\"sub\":\"$uid\",\"role\":\"authenticated\"}';
$sql
rollback;
" 2>&1
}
scalar() { $PSQL -t -A -q -c "$1"; }
expect_ok() { if echo "$2" | grep -qiE "ERROR|exception"; then fail "$1" "esperado sucesso, mas houve erro:\n$2"; else pass "$1"; fi; }
expect_error() { if echo "$2" | grep -qiE "$3"; then pass "$1"; else fail "$1" "esperado erro casando com /$3/i — saída real:\n$2"; fi; }

echo "############################################################"
echo "# PASSO 0 — REPLAY COMPLETO DO ZERO (todas as $(ls supabase/migrations/*.sql | wc -l) migrations) #"
echo "############################################################"
dropdb -h localhost -U optimon_admin optimon_replay39 2>/dev/null || true
createdb -h localhost -U optimon_admin optimon_replay39
psql -h localhost -U optimon_admin -d optimon_replay39 -v ON_ERROR_STOP=1 -f supabase/dev-local-only/shim_supabase_auth.sql > /tmp/fase39_replay.log 2>&1
REPLAY_OK=1
for f in supabase/migrations/*.sql; do
  psql -h localhost -U optimon_admin -d optimon_replay39 -v ON_ERROR_STOP=1 -f "$f" >> /tmp/fase39_replay.log 2>&1 || { REPLAY_OK=0; echo "FALHOU: $f"; break; }
done
if [ "$REPLAY_OK" = "1" ]; then
  pass "PASSO-0 replay completo do zero de todas as migrations — 0 erros"
else
  fail "PASSO-0 replay completo do zero" "ver /tmp/fase39_replay.log — abortando bateria"
  dropdb -h localhost -U optimon_admin optimon_replay39 2>/dev/null || true
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
dropdb -h localhost -U optimon_admin optimon_replay39

echo "############################################################"
echo "# CATEGORIA A — schema novo (migration 20260930090000)     #"
echo "############################################################"

DIRETOR=$(scalar "select id from usuarios where perfil in ('DIRETOR','ADMINISTRADOR') limit 1;")
NAOPRIV=$(scalar "select id from usuarios where perfil not in ('DIRETOR','ADMINISTRADOR') limit 1;")
CID=$(scalar "select id from contratos where status='ATIVO' order by criado_em limit 1;")
if [ -z "$CID" ] || [ -z "$DIRETOR" ] || [ -z "$NAOPRIV" ]; then
  fail "CATEGORIA-A pré-condição" "faltam dados de seed (contrato ATIVO / usuário DIRETOR / usuário não-privilegiado) — abortando categoria"
else
  R=$(as_role "$DIRETOR" "insert into contrato_rescisao_config (contrato_id, tipo_multa, percentual_multa) values ('$CID','PERCENTUAL_SALDO_MINIMO',0.10); select 'MARK_A01:' || (definido_por = '$DIRETOR'::uuid) || ':' || (definido_em is not null) from contrato_rescisao_config where contrato_id='$CID';")
  echo "$R" | grep -q "MARK_A01:true:true" && pass "A01 contrato_rescisao_config: INSERT como DIRETOR funciona e trigger carimba definido_por/definido_em automaticamente" || fail "A01" "$R"

  R=$(as_role "$NAOPRIV" "insert into contrato_rescisao_config (contrato_id, tipo_multa) values ('$CID','VALOR_FIXO');")
  expect_error "A02 contrato_rescisao_config: INSERT como perfil não-DIRETOR é bloqueado pela RLS" "$R" "row-level security"

  R=$(as_role "$DIRETOR" "update contrato_regras set mecanismo_protecao_carteira='OPCAO_C_COMPENSACAO_ECONOMICA', detalhe_protecao_carteira='teste' where contrato_id='$CID'; select mecanismo_protecao_carteira from contrato_regras where contrato_id='$CID';")
  echo "$R" | grep -q "OPCAO_C_COMPENSACAO_ECONOMICA" && pass "A03 contrato_regras.mecanismo_protecao_carteira: escrita como DIRETOR funciona" || fail "A03" "$R"

  R=$(as_role "$DIRETOR" "update contrato_pricing_config set take_or_pay_clientes=20 where contrato_id='$CID'; select 'MARK_A04:' || take_or_pay_clientes from contrato_pricing_config where contrato_id='$CID';")
  echo "$R" | grep -q "MARK_A04:20" && pass "A04 contrato_pricing_config.take_or_pay_clientes: escrita como DIRETOR funciona" || fail "A04" "$R"

  for TIPO in ALTERACAO_CAPACIDADE ALTERACAO_EXCLUSIVIDADE ALTERACAO_REGRAS_COBRANCA; do
    N=$(scalar "select coalesce(max(numero),0)+1 from contrato_aditivos where contrato_id='$CID';")
    R=$(as_role "$DIRETOR" "insert into contrato_aditivos (contrato_id, numero, tipo, descricao) values ('$CID', $N, '$TIPO', 'teste fase 3.9');")
    expect_ok "A05-$TIPO contrato_aditivos_tipo_check aceita o tipo já oferecido pelo frontend (ContractDetail.jsx TIPOS_ADITIVO)" "$R"
  done
fi

echo "############################################################"
echo "# CATEGORIA B — app.contrato_documento_dados() expõe os novos campos #"
echo "############################################################"

if [ -n "${CID:-}" ]; then
  DADOS=$(scalar "select app.contrato_documento_dados('$CID');")
  for CAMPO in rescisao_config ativos_devolucao clientes_ativos_contrato infraestrutura_detalhe rampa; do
    echo "$DADOS" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$CAMPO' in d else 1)" \
      && pass "B01-$CAMPO app.contrato_documento_dados() inclui a chave '$CAMPO'" \
      || fail "B01-$CAMPO" "chave ausente no jsonb retornado"
  done
else
  fail "CATEGORIA-B pré-condição" "sem contrato de teste — abortando categoria"
fi

echo "############################################################"
echo "# CATEGORIA C — buildContractDocumentModel() gera os 21 marcadores do §30 #"
echo "############################################################"

if [ -n "${CID:-}" ]; then
  DADOS_FILE=$(mktemp)
  $PSQL -t -A -q -c "select app.contrato_documento_dados('$CID');" > "$DADOS_FILE"

  RESULT=$(node -e "
    const { buildContractDocumentModel } = require('$ROOT/api/lib/contractDocumentModel.js');
    const fs = require('fs');
    const dados = JSON.parse(fs.readFileSync('$DADOS_FILE', 'utf8'));
    const m = buildContractDocumentModel(dados);
    const full = JSON.stringify(m.sections);
    const marcadores = {
      'prazo-48-meses': /48.*mes|prazo m[ií]nimo/i,
      'recurso-pon-fibra': /porta pon|fibra apagada/i,
      'minimo-mensal': /take-or-pay|m[ií]nimo mensal garantido/i,
      'variavel-revenue-share': /revenue share/i,
      'take-or-pay-clientes': /take-or-pay em quantidade de clientes/i,
      'rampa': /rampa de matura[cç][ãa]o/i,
      'reajuste': /reajuste anual/i,
      'clientes-reservados': /clientes reservados/i,
      'restricao-rede-concorrente': /rede pr[óo]pria.*proibid|proibido de construir rede pr[óo]pria/i,
      'restricao-prefeitura': /prefeitura/i,
      'responsabilidade-cliente-final': /responsabilidade pela instala[cç][ãa]o do cliente final/i,
      'propriedade-ativos': /propriedade dos ativos/i,
      'devolucao-ativos': /devolu[cç][ãa]o de ativos/i,
      'regras-rescisao': /multa por rescis[ãa]o antecipada/i,
      'venda-transferencia-operacao': /venda.*transfer[êe]ncia da opera[cç][ãa]o/i,
      'direito-nick-recursos': /direito.*explorar comercialmente a capacidade.*remanescente/i,
      'ausencia-sociedade': /n[ãa]o constitui.*sociedade/i,
      'natureza-cessao-onerosa': /cess[ãa]o onerosa/i,
      'nunca-rede-neutra': /N[ÃA]O caracteriza.*rede neutra/i,
      'protecao-carteira': /prote[cç][ãa]o da carteira de clientes/i,
    };
    let ok = true;
    for (const [nome, re] of Object.entries(marcadores)) {
      const achou = re.test(full);
      console.log((achou ? 'OK' : 'MISSING') + ' ' + nome);
      if (!achou) ok = false;
    }
    const temAssinatura = m.sections.some((s) => s.tipo === 'assinatura');
    console.log((temAssinatura ? 'OK' : 'MISSING') + ' assinatura');
    if (!temAssinatura) ok = false;
    process.exit(ok ? 0 : 1);
  " 2>&1)
  STATUS=$?
  echo "$RESULT" | sed 's/^/  /'
  if [ "$STATUS" -eq 0 ]; then
    pass "C01 buildContractDocumentModel(): todos os 21 marcadores exigidos pelo §30 (REGRA CRÍTICA) estão presentes no modelo de cláusulas gerado"
  else
    fail "C01 buildContractDocumentModel(): marcador(es) ausente(s)" "$(echo "$RESULT" | grep MISSING)"
  fi
  rm -f "$DADOS_FILE"
else
  fail "CATEGORIA-C pré-condição" "sem contrato de teste — abortando categoria"
fi

echo "############################################################"
echo "# CATEGORIA D — geradores PDF/DOCX consomem o modelo sem erro real #"
echo "############################################################"

if [ -n "${CID:-}" ]; then
  DADOS_FILE=$(mktemp)
  $PSQL -t -A -q -c "select app.contrato_documento_dados('$CID');" > "$DADOS_FILE"
  R=$(node -e "
    const { generateContratoPdf } = require('$ROOT/api/lib/pdfContrato.js');
    const { generateContratoDocx } = require('$ROOT/api/lib/docxContrato.js');
    const fs = require('fs');
    const dados = JSON.parse(fs.readFileSync('$DADOS_FILE', 'utf8'));
    Promise.all([generateContratoPdf(dados), generateContratoDocx(dados)])
      .then(([pdf, docx]) => {
        if (!pdf.slice(0,4).toString('latin1').startsWith('%PDF')) throw new Error('PDF sem header %PDF');
        if (docx.length < 1000) throw new Error('DOCX suspeito de vazio');
        console.log('PDF_BYTES=' + pdf.length + ' DOCX_BYTES=' + docx.length);
      })
      .catch(e => { console.error('ERRO: ' + e.message); process.exit(1); });
  " 2>&1)
  echo "$R" | grep -q "PDF_BYTES=" && pass "D01 generateContratoPdf()/generateContratoDocx(): geram documentos reais e válidos a partir do modelo de cláusulas da Fase 3.9 ($R)" || fail "D01" "$R"
  rm -f "$DADOS_FILE"
else
  fail "CATEGORIA-D pré-condição" "sem contrato de teste — abortando categoria"
fi

echo "############################################################"
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falharam: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
