# OptiMon — OptiMap: aplica no Supabase de PRODUÇÃO as migrations que ainda faltam
# (Importação de Infraestrutura 4.1 + OptiMap Fases 2, 4 e 5), em UMA transação.
#
# Uso (PowerShell, na raiz do repositório):
#   $env:DATABASE_URL = "<connection string do Supabase — Project Settings > Database > Session pooler>"
#   .\scripts\optimap_deploy_producao.ps1 -SoVerificar     # só mostra o estado, não altera nada
#   .\scripts\optimap_deploy_producao.ps1                  # verifica, pede confirmação e aplica
#
# Garantias:
#   * Só aplica grupos que estão AUSENTES por completo; se algum grupo estiver pela metade, para.
#   * Tudo numa única transação (psql -1 + ON_ERROR_STOP): ou aplica tudo, ou nada.
#   * Nenhuma migration histórica é alterada; nenhum dado existente é apagado; sem reset.
#   * A senha fica só na variável de ambiente desta janela — o script nunca a grava nem exibe.

param([switch]$SoVerificar)
$ErrorActionPreference = 'Stop'

if (-not $env:DATABASE_URL) {
  Write-Host 'Defina antes:  $env:DATABASE_URL = "postgresql://postgres.<ref>:<senha>@<host>:5432/postgres"' -ForegroundColor Yellow
  Write-Host '(Supabase > Project Settings > Database > Connection string > Session pooler)'
  exit 1
}
# psql: usa o do PATH; se não houver, procura a instalação padrão do PostgreSQL no Windows.
$psql = (Get-Command psql -ErrorAction SilentlyContinue).Source
if (-not $psql) {
  $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe', 'C:\Program Files (x86)\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
    Sort-Object { [int]($_.Directory.Parent.Name -replace '\D', '') } -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $psql) { Write-Host 'psql não encontrado (nem no PATH, nem em C:\Program Files\PostgreSQL\<versão>\bin).' -ForegroundColor Red; exit 1 }
Write-Host "psql: $psql"
$env:PGCLIENTENCODING = 'UTF8'   # sem isto o Windows envia WIN1252 e os acentos quebram

$raiz = Split-Path -Parent $PSScriptRoot
$mig = Join-Path $raiz 'supabase\migrations'

function Q([string]$sql) {
  $r = & $psql $env:DATABASE_URL -X -At -v ON_ERROR_STOP=1 -c $sql
  if ($LASTEXITCODE -ne 0) { throw "Consulta falhou: $sql" }
  return (($r | Out-String).Trim())
}
function Existe-Funcao([string]$schema, [string]$nome) {
  return (Q "select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = '$schema' and p.proname = '$nome')") -eq 't'
}
function Existe-Tabela([string]$nome) { return (Q "select to_regclass('$nome') is not null") -eq 't' }

$grupos = @(
  @{ nome = 'Importação de Infraestrutura (Fase 4.1)';
     arquivos = @('20261011090000_phase_4_1_01_staging_importacao_schema.sql', '20261011100000_phase_4_1_02_auditoria_import_whitelist.sql',
                  '20261012090000_phase_4_1_03_importacao_classificacao.sql', '20261012100000_phase_4_1_04_importacao_aplicar.sql',
                  '20261013090000_phase_4_1_05_importacao_reverter.sql');
     inicio = { Existe-Tabela 'staging.importacoes' }; fim = { Existe-Funcao 'app' 'reverter_importacao' } },
  @{ nome = 'OptiMap Fase 2 (fundação geográfica / PostGIS)';
     arquivos = @('20261021090000_optimap_2_01_postgis.sql', '20261021090100_optimap_2_02_schema.sql',
                  '20261021090200_optimap_2_03_regras_e_funcoes.sql', '20261021090300_optimap_2_04_rls_auditoria.sql');
     inicio = { Existe-Tabela 'public.gis_fontes' }; fim = { Existe-Funcao 'public' 'optimap_arquivar' } },
  @{ nome = 'OptiMap Fase 4 (importação de postes de referência)';
     arquivos = @('20261022090000_optimap_4_01_staging_importacao_gis.sql', '20261022090100_optimap_4_02_funcoes_importacao_gis.sql');
     inicio = { Existe-Tabela 'staging.gis_importacoes' }; fim = { Existe-Funcao 'public' 'optimap_importacao_previa_geojson' } },
  @{ nome = 'OptiMap Fase 5 (empresas, ocupações, CES, cores)';
     arquivos = @('20261027090000_optimap_5_01_empresas_ocupacoes.sql', '20261027090100_optimap_5_02_funcoes_ces_ocupacoes.sql');
     inicio = { Existe-Tabela 'public.gis_empresas' }; fim = { Existe-Funcao 'public' 'optimap_ces_conferencia' } }
)

Write-Host '== Banco de produção' -ForegroundColor Cyan
Write-Host ("Postgres: " + (Q "select current_setting('server_version')"))
Write-Host ("Tamanho atual: " + (Q "select pg_size_pretty(pg_database_size(current_database()))"))
# Atenção: texto passado ao psql pela linha de comando sai na codificação do console do
# Windows (não UTF-8). Por isso as consultas abaixo usam só caracteres sem acento.
$postgis = Q "select coalesce((select default_version from pg_available_extensions where name = 'postgis'), 'INDISPONIVEL')"
Write-Host ("PostGIS disponível: " + $postgis)

$aplicar = @()
$parcial = $false
foreach ($g in $grupos) {
  $i = & $g.inicio; $f = & $g.fim
  $estado = if ($i -and $f) { 'JÁ APLICADO' } elseif (-not $i -and -not $f) { 'PENDENTE' } else { 'PELA METADE' }
  $cor = @{ 'JÁ APLICADO' = 'Green'; 'PENDENTE' = 'Yellow'; 'PELA METADE' = 'Red' }[$estado]
  Write-Host ("  {0,-55} {1}" -f $g.nome, $estado) -ForegroundColor $cor
  if ($estado -eq 'PENDENTE') { $aplicar += $g.arquivos }
  if ($estado -eq 'PELA METADE') { $parcial = $true }
}
foreach ($a in $aplicar) { if (-not (Test-Path (Join-Path $mig $a))) { Write-Host "Arquivo não encontrado: $a" -ForegroundColor Red; exit 1 } }

if ($parcial) {
  Write-Host 'Há grupo aplicado pela metade. Nada foi alterado. Me envie esta saída para analisarmos antes de seguir.' -ForegroundColor Red
  exit 1
}
if ($aplicar.Count -eq 0) { Write-Host 'Nada a aplicar: tudo já está no banco.' -ForegroundColor Green; exit 0 }
if ($postgis -eq 'INDISPONIVEL' -and ($aplicar -contains '20261021090000_optimap_2_01_postgis.sql')) {
  Write-Host 'PostGIS não está disponível neste projeto. Nada foi alterado.' -ForegroundColor Red; exit 1
}

Write-Host ''
Write-Host ("Serão aplicadas {0} migrations, nesta ordem, numa única transação:" -f $aplicar.Count) -ForegroundColor Cyan
$aplicar | ForEach-Object { Write-Host "  - $_" }
if ($SoVerificar) { Write-Host '(modo -SoVerificar: nada foi alterado)'; exit 0 }

$ok = Read-Host 'Digite APLICAR para continuar'
if ($ok -ne 'APLICAR') { Write-Host 'Cancelado. Nada foi alterado.'; exit 1 }

# Junta os arquivos num único script temporário (UTF-8 sem BOM) e aplica em 1 transação.
$tmp = Join-Path $env:TEMP ("optimap_deploy_{0}.sql" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sb = New-Object System.Text.StringBuilder
foreach ($a in $aplicar) {
  [void]$sb.AppendLine("\echo '>> $a'")
  [void]$sb.AppendLine([System.IO.File]::ReadAllText((Join-Path $mig $a), $utf8))
  [void]$sb.AppendLine('')
}
[System.IO.File]::WriteAllText($tmp, $sb.ToString(), $utf8)

& $psql $env:DATABASE_URL -X -1 -v ON_ERROR_STOP=1 -f $tmp
$rc = $LASTEXITCODE
Remove-Item $tmp -ErrorAction SilentlyContinue
if ($rc -ne 0) {
  Write-Host 'ERRO: a transação foi desfeita por inteiro — o banco ficou exatamente como antes. Me envie a mensagem acima.' -ForegroundColor Red
  exit 1
}

Q "notify pgrst, 'reload schema'" | Out-Null
Write-Host ''
Write-Host '== Conferência pós-aplicação' -ForegroundColor Cyan
foreach ($g in $grupos) {
  $i = & $g.inicio; $f = & $g.fim
  Write-Host ("  {0,-55} {1}" -f $g.nome, $(if ($i -and $f) { 'OK' } else { 'FALTANDO' }))
}
Write-Host ("Fontes GIS: " + (Q "select string_agg(codigo || ' (' || tipo || ')', ', ' order by codigo) from public.gis_fontes"))
if (Existe-Tabela 'public.gis_empresas') {
  Write-Host ("Empresas: " + (Q "select string_agg(coalesce(nome_fantasia, razao_social) || ' (UC ' || coalesce(uc_copel, '-') || ')', ', ' order by razao_social) from public.gis_empresas"))
}
Write-Host ("Tamanho do banco: " + (Q "select pg_size_pretty(pg_database_size(current_database()))"))
Write-Host 'Pronto. Cache do PostgREST recarregado.' -ForegroundColor Green
