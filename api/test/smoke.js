// OptiMon Pricing API — smoke test (seção 4/44). Roda em CI sem banco/Supabase real
// (SUPABASE_URL/ANON_KEY são placeholders) — só prova que o server Express sobe, que
// /health e /api/version respondem com o contrato exato exigido (seção 6/40), e que
// rotas de negócio exigem autenticação (401 sem Authorization). Testes de verdade contra
// o Pricing Engine (SQL) vivem em tests/run_tests_*.sh e tests/run_tests_deploy.sh, que
// exigem um Postgres com o schema completo — fora do escopo deste smoke test leve.

const http = require('http');
const assert = require('assert');

process.env.SUPABASE_URL = process.env.SUPABASE_URL || 'https://ci-placeholder.supabase.co';
process.env.SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'ci-placeholder-anon-key';

const app = require('../server');

let failures = 0;
function check(name, cond) {
  if (cond) {
    console.log(`PASS | ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL | ${name}`);
  }
}

function request(server, path, opts = {}) {
  return new Promise((resolve, reject) => {
    const { port } = server.address();
    const req = http.request({ hostname: '127.0.0.1', port, path, method: opts.method || 'GET', headers: opts.headers || {} }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

async function main() {
  const server = app.listen(0);
  await new Promise((resolve) => server.once('listening', resolve));

  const health = await request(server, '/health');
  check('GET /health -> 200', health.status === 200);
  const healthBody = JSON.parse(health.body);
  check('GET /health -> {"status":"ok","service":"optimon-api"}', healthBody.status === 'ok' && healthBody.service === 'optimon-api');

  const version = await request(server, '/api/version');
  check('GET /api/version -> 200', version.status === 200);
  const versionBody = JSON.parse(version.body);
  check('GET /api/version tem "version" e "service"', typeof versionBody.version === 'string' && versionBody.service === 'optimon-api');
  check('GET /api/version nunca inclui SUPABASE_ANON_KEY/segredos', !JSON.stringify(versionBody).match(/ci-placeholder-anon-key/));

  const noAuth = await request(server, '/api/cities');
  check('GET /api/cities sem Authorization -> 401', noAuth.status === 401);

  const noAuthPricing = await request(server, '/api/pricing/current-role');
  check('GET /api/pricing/current-role sem Authorization -> 401', noAuthPricing.status === 401);

  // OptiMap (Fase 3): mapa nunca anônimo — tiles, busca e detalhe exigem JWT.
  const noAuthTile = await request(server, '/api/optimap/tiles/pops/10/1/1.mvt');
  check('GET /api/optimap/tiles/... sem Authorization -> 401', noAuthTile.status === 401);
  const noAuthBusca = await request(server, '/api/optimap/buscar?q=poste');
  check('GET /api/optimap/buscar sem Authorization -> 401', noAuthBusca.status === 401);
  // OptiMap (Fase 4): importações também nunca anônimas.
  const noAuthImp = await request(server, '/api/optimap/importacoes');
  check('GET /api/optimap/importacoes sem Authorization -> 401', noAuthImp.status === 401);
  const noAuthImpPost = await request(server, '/api/optimap/importacoes', { method: 'POST' });
  check('POST /api/optimap/importacoes sem Authorization -> 401', noAuthImpPost.status === 401);

  // Leitor do arquivo do coletor: confere formato e o hash gravado pelo coletor.
  const { _lerArquivo } = require('../routes/optimapImportacoes');
  const crypto = require('crypto');
  const features = [{ type: 'Feature', geometry: { type: 'Point', coordinates: [-52.46, -23.62] },
    properties: { num_seq_geo: '123', situacao: 'Disponível', indic_ps_particular: 'N', objectid: 9 } }];
  const meta = { formato: 'optimap-referencia-postes/1', fonte: 'COPEL_MAPA_PUBLICO', total: 1,
    sha256_features: crypto.createHash('sha256').update(JSON.stringify(features)).digest('hex') };
  const ok = _lerArquivo(Buffer.from(JSON.stringify({ type: 'FeatureCollection', optimap: meta, features })));
  check('leitor: arquivo íntegro vira itens {linha,id_externo,lon,lat,situacao}', ok.itens.length === 1 && ok.itens[0].id_externo === '123' && ok.itens[0].lon === -52.46 && ok.itens[0].situacao === 'Disponível');
  let recusado = false;
  try { features[0].geometry.coordinates[0] = -52.47; _lerArquivo(Buffer.from(JSON.stringify({ type: 'FeatureCollection', optimap: meta, features }))); } catch (e) { recusado = /hash/.test(e.message); }
  check('leitor: arquivo editado após a coleta (hash não confere) é recusado', recusado);
  let semCab = false;
  try { _lerArquivo(Buffer.from(JSON.stringify({ type: 'FeatureCollection', features }))); } catch (e) { semCab = /cabeçalho/.test(e.message); }
  check('leitor: GeoJSON sem cabeçalho do coletor é recusado', semCab);

  server.close();

  console.log('');
  if (failures > 0) {
    console.error(`${failures} teste(s) falharam.`);
    process.exit(1);
  }
  console.log('Todos os smoke tests passaram.');
}

main().catch((err) => {
  console.error('Smoke test travou com erro:', err);
  process.exit(1);
});
