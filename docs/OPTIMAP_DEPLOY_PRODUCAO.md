# OptiMap — Publicação em produção (Fases 2, 3 e 4) — passo a passo

Autorizado pelo usuário em 23/10/2026.

A aplicação no banco, o `git push` e a troca de plano são feitos **por você**, no seu computador e nos painéis. Esses passos usam suas credenciais, e eu nunca as manuseio. Tudo o que não depende de credencial já está pronto no repositório.

Validação feita antes desta entrega:

- simulei o banco de produção com as 126 migrations já publicadas e o seed real de Jussara;
- apliquei por cima as 11 migrations novas, **numa única transação**: levou ~3 s e terminou sem erro.

---

## 0. Antes de começar

1. **Plano Pro do Supabase:**
   - abra o painel → *Organization* → *Billing* e mude o plano para **Pro**;
   - confirme em *Database → Backups* que existe um backup diário recente.
2. Abra o PowerShell na pasta do repositório:
   ```powershell
   cd "E:\OneDrive\Downloads\Projetos Claude\OptiMon - Cessão de Rede\optimon"
   ```

## 1. Banco de dados (Supabase de produção)

Primeiro, pegue a connection string:

1. No painel, abra *Project Settings → Database → Connection string*.
2. Escolha **Session pooler**, porta 5432.
3. Copie a string e troque `[YOUR-PASSWORD]` pela senha do banco.

Depois, rode:

```powershell
$env:DATABASE_URL = "postgresql://postgres.zmhektrjgrjvcsysrbmw:SUA_SENHA@aws-0-....pooler.supabase.com:5432/postgres"

# 1º: só verifica (não altera nada)
.\scripts\optimap_deploy_producao.ps1 -SoVerificar

# 2º: aplica (pede para digitar APLICAR)
.\scripts\optimap_deploy_producao.ps1
```

Na verificação, o script mostra três grupos, cada um com o seu estado:

- Importação de Infraestrutura (Fase 4.1);
- OptiMap Fase 2;
- OptiMap Fase 4.

O estado esperado é **PENDENTE** para os três: o script aplica as 11 migrations de uma vez.

Como o script se comporta:

| Situação | O que acontece |
|---|---|
| Algum grupo aparece **JÁ APLICADO** | O script pula esse grupo. |
| Algum grupo aparece **PELA METADE** | O script para sem alterar nada. Me mande a saída. |
| Dá erro no meio da aplicação | A transação inteira é desfeita e o banco fica como estava. Me mande a mensagem. |

Ao final, o script recarrega o cache da API do Supabase e mostra:

- as fontes GIS cadastradas: `COPEL_MAPA_PUBLICO` e as três fontes `NICK_*`;
- o novo tamanho do banco.

Quando terminar, feche o PowerShell ou rode `Remove-Item Env:DATABASE_URL` para tirar a senha da memória da janela.

## 2. API (Railway) e telas (Vercel)

O código já está na sua pasta. Publique com:

```powershell
git status
git add .gitignore api web supabase/migrations tools/optimap/coletar_copel.mjs tools/optimap/teste_coleta_copel.mjs `
        tests/optimap docs scripts/optimap_deploy_producao.ps1
git commit -m "OptiMap: mapa (Fase 3) e importação de postes de referência (Fase 4)"
git push origin main
```

- O `.gitignore` agora ignora `tools/optimap/saida/`. Os arquivos coletados da Copel **não** vão para o GitHub.
- O push dispara o redeploy automático do Railway e da Vercel. Acompanhe os logs nos dois painéis.
- O frontend instala a biblioteca de mapa `maplibre-gl`; o `package-lock.json` já está atualizado.

## 3. Conferência rápida

1. Entre no OptiMon com um usuário ADMINISTRADOR e abra **OptiMap**.
2. O mapa deve abrir com as camadas zeradas.
3. Na barra inferior, clique em **Importações de postes**. Deve aparecer a lista vazia, com o formulário de envio.

## 4. Importar os postes (pela tela)

Os arquivos estão em `tools\optimap\saida\copel_<ibge>_<cidade>\copel_<ibge>_<cidade>_2026-10-22.geojson`.

Comece por **Jussara**. Para cada município:

1. **Enviar:** como ENGENHARIA ou ADMINISTRADOR, escolha o arquivo e clique em *Enviar e gerar prévia*.
2. **Conferir:** veja os cartões e o mapa da prévia. Na 1ª carga, tudo aparece como **Novo**.
3. **Aprovar:** como ADMINISTRADOR ou DIRETOR, use *Aprovar e importar*.

Repita para os 17 municípios: os 15 do piloto, mais Jacarezinho (63 postes) e Ribeirão Claro (100), conforme a sua decisão.

Se aparecer **“A operação demorou demais”**, nada foi aplicado. Me avise. Isso indicaria que o limite de tempo maior, configurado só para essas funções, não está valendo na API do seu projeto Supabase, e eu ajusto.

Volume esperado: cerca de 130,9 mil postes, ~150 MB a mais no banco.

## 5. Depois

- Os municípios que ainda não são cidades no OptiMon recebem o aviso “sem cidade associada”. Ao cadastrar a cidade (com o código IBGE), a próxima coleta faz o vínculo automaticamente.
- **Recoletas:** rode `node tools\optimap\coletar_copel.mjs --cidade "<Nome>"` e importe o arquivo novo pela mesma tela.
  - Os postes que sumirem viram “não localizado na última coleta”; nada é apagado.
  - Cada recoleta completa adiciona ~100 MB ao banco, o que é tranquilo no plano Pro.

---

## Fase 5 — empresas, ocupações, CES e cores (27/10/2026)

Esta fase é publicada pelo **mesmo script** da seção 1. Os grupos já aplicados aparecem como **JÁ APLICADO** e são pulados. Só o grupo **OptiMap Fase 5** fica **PENDENTE**, com 2 migrations.

```powershell
.\scripts\optimap_deploy_producao.ps1 -SoVerificar   # Fase 5 deve aparecer PENDENTE
.\scripts\optimap_deploy_producao.ps1                # digite APLICAR
```

Ao final, o script lista as empresas cadastradas: NICK NETWORK (UC 515903403178) e AYOTECH (UC 638231603159).

Depois, publique o código:

```powershell
git add api web supabase/migrations tests/optimap docs scripts/optimap_deploy_producao.ps1
git commit -m "OptiMap Fase 5: empresas, ocupações, listas do CES e cores dos postes"
git push origin main
```

Por último, carregue as listas do CES:

1. No OptiMap, abra **Listas do CES**.
2. Envie os arquivos de `tools\optimap\saida\ces\`:
   - `ces_08930086000163_nick_2026-10-27.geojson` (5.341 postes);
   - `ces_30353855000167_ayotech_2026-10-27.geojson` (391 postes).
3. Como ADMINISTRADOR ou DIRETOR, aprove cada lista.

Detalhes no `docs/OPTIMAP_FASE_5_RELATORIO.md`.
