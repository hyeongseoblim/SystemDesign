// 핵심 학습 규칙·콘텐츠 연결 회귀 검증. 외부 API·DB 없이 실행한다.
const { test, after } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const web = path.join(root, 'apps/web');
const output = mkdtempSync(path.join(tmpdir(), 'jobstudy-study-test-'));
execFileSync(process.execPath, [path.join(web, 'node_modules/typescript/bin/tsc'),
  path.join(web, 'lib/study.ts'), path.join(web, 'lib/reading.ts'), '--outDir', output,
  '--module', 'commonjs', '--target', 'ES2022', '--skipLibCheck', '--types', 'node',
  '--typeRoots', path.join(web, 'node_modules/@types')]);
const { matchesSearch, matchesStudy, needsReview, readStudy, writeStorage, shuffleRank } = require(path.join(output, 'study.js'));
const { headings, sectionId } = require(path.join(output, 'reading.js'));
after(() => rmSync(output, { recursive: true, force: true }));

test('검색은 제목·태그·요약, 대소문자와 공백 분리 검색어를 지원한다', () => {
  const card = { title: 'Kafka 소비자', summary: '중복 이벤트와 복구', tags: ['Outbox'] };
  assert.equal(matchesSearch(card, ' KAFKA   outbox '), true);
  assert.equal(matchesSearch(card, '복구 이벤트'), true);
  assert.equal(matchesSearch(card, 'Postgres'), false);
  assert.equal(matchesSearch(card, '   '), true);
});
test('완료 여부와 이해도는 독립적이고 힌트 필요도 복습에 포함한다', () => {
  const record = { read: '2026-09-08', done: '2026-09-08', mastery: 'hint' };
  assert.equal(matchesStudy(record, 'complete'), true);
  assert.equal(matchesStudy(record, 'review'), true);
  assert.equal(matchesStudy(record, 'reading'), false);
  assert.equal(matchesStudy(record, 'new'), false);
  assert.equal(needsReview({ ...record, mastery: 'confident' }), false);
  assert.equal(matchesStudy({}, 'new'), true);
  assert.equal(matchesStudy({ read: 'today' }, 'reading'), true);
});
test('기존 읽음·완료 키를 유지하고 손상된 이해도 값은 무시한다', () => {
  const values = new Map([['jobStudy::read::id', 'read-date'], ['jobStudy::done::id', 'done-date'], ['jobStudy::mastery::id', 'unknown']]);
  global.localStorage = { getItem: (key) => values.get(key) ?? null };
  assert.deepEqual(readStudy('id'), { read: 'read-date', done: 'done-date', mastery: undefined });
});
test('저장소 접근이 차단돼도 예외 대신 저장 실패를 반환한다', () => {
  global.localStorage = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('quota'); } };
  assert.deepEqual(readStudy('id'), { read: undefined, done: undefined, mastery: undefined });
  assert.equal(writeStorage('id', 'value'), false);
});
test('랜덤 정렬 키는 동일한 시드에서 복귀·재조회 후에도 유지된다', () => {
  const ids = ['card-a', 'card-b', 'card-c', 'card-d'];
  const sort = (values) => [...values].sort((a,b) => shuffleRank(a, 42) - shuffleRank(b, 42));
  assert.deepEqual(sort(ids), sort([...ids].reverse()));
  assert.notEqual(shuffleRank('card-a', 42), shuffleRank('card-a', 43));
});
test('목차는 코드 펜스 안의 제목과 중복 질문 섹션을 제외한다', () => {
  assert.deepEqual(headings('## 1. **핵심**\n```md\n## 예시\n```\n## 이해도 확인\n'), [{ title: '1. 핵심', id: sectionId('1. 핵심') }]);
});
test('34개 카드의 102개 점검 기준은 실제 질문과 정확히 연결된다', () => {
  const guides = JSON.parse(readFileSync(path.join(web, 'content/answer-guides.json'), 'utf8'));
  assert.equal(Object.keys(guides).length, 34);
  for (const [slug, guide] of Object.entries(guides)) {
    const raw = readFileSync(path.join(root, `apps/api/src/main/resources/content/${slug}.md`), 'utf8');
    const questions = raw.split('---')[1].split('questions:\n')[1].trim().split('\n').map(line => JSON.parse(line.trim().slice(2)));
    assert.deepEqual(guide.questions.map(item => item.question), questions, slug);
    for (const item of guide.questions) {
      assert.equal(item.points.length, 3);
      assert.ok(item.pitfall && item.followUp);
    }
    assert.ok(guide.sources.every(source => new URL(source.url).protocol === 'https:'));
  }
});
test('V8은 검수 본문을 정확히 반영하고 기존 질문·카드 ID를 변경하지 않는다', () => {
  const directory = path.join(root, 'apps/api/src/main/resources');
  const source = readFileSync(path.join(directory, 'content/database-01-index-explain.md'), 'utf8').split('---').slice(2).join('---').trim();
  const migration = readFileSync(path.join(directory, 'db/migration/V8__review_index_card.sql'), 'utf8');
  assert.equal(migration.split('$card_body$')[1], source);
  assert.match(migration, /WHERE slug = 'database-01-index-explain' AND source = 'MANUAL'/);
  assert.doesNotMatch(migration, /DELETE FROM|UPDATE card_questions|SET id\s*=/i);
});

// SQL 본문은 마크다운 코드 예제도 포함하므로 UPDATE 바깥 구조만 파싱한다.
test('V9는 검수한 32개 MANUAL 카드의 본문만 갱신하고 원본과 일치한다', () => {
  const directory = path.join(root, 'apps/api/src/main/resources');
  const sql = readFileSync(path.join(directory, 'db/migration/V9__review_existing_content.sql'), 'utf8');
  const statements = [...sql.matchAll(/UPDATE cards\nSET content_md = (\$review_\d+\$)([\s\S]*?)\1\nWHERE slug = '([^']+)' AND source = 'MANUAL';/g)];
  const expected = [
    'backend-02-concurrency',
    'backend-03-transaction',
    'backend-04-resilience-idempotency',
    'backend-07-interview-concurrency',
    'backend-architecture-01-msa-vs-monolith',
    'backend-architecture-03-event-driven',
    'backend-architecture-04-saga',
    'backend-architecture-06-outbox-idempotency',
    'backend-architecture-07-interview-saga',
    'backend-architecture-11-idempotent-consumer-design',
    'database-02-lock-isolation',
    'database-03-mvcc-internals',
    'database-05-rdbms-vs-nosql',
    'database-07-inventory-concurrency',
    'database-08-interview-index-lock',
    'infra-12-kubernetes-resource-management',
    'logistics-10-order-promise',
    'logistics-11-inventory-ledger',
    'logistics-12-sku-barcode-serial',
    'logistics-13-scan-event-correction-design',
    'logistics-14-carrier-gateway-design',
    'logistics-15-rocket-delivery-design',
    'logistics-16-realtime-dispatch-design',
    'logistics-17-fulfillment-operations-interview',
    'logistics-18-slotting-optimization',
    'logistics-19-event-pipeline-interview',
    'system-design-07-consistency-consensus',
    'system-design-17-replication-protocols',
    'system-design-18-distributed-clocks',
    'system-design-21-distributed-lock-design',
    'system-design-25-transaction-isolation',
    'system-design-26-message-queue-selection',
  ];
  assert.deepEqual(statements.map(match => match[3]).sort(), expected.sort());
  let remainder = sql;
  for (const [statement, , body, slug] of statements) {
    const source = readFileSync(path.join(directory, `content/${slug}.md`), 'utf8').split('---').slice(2).join('---').trim();
    assert.equal(body, source, slug);
    remainder = remainder.replace(statement, '');
  }
  assert.equal(remainder.replace(/^--.*$/gm, '').trim(), '', '검수 본문 UPDATE 외 SQL은 허용하지 않는다');
});
