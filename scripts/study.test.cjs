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
test('10개 카드의 30개 점검 기준은 실제 질문과 정확히 연결된다', () => {
  const guides = JSON.parse(readFileSync(path.join(web, 'content/answer-guides.json'), 'utf8'));
  assert.equal(Object.keys(guides).length, 10);
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
