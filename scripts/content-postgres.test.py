"""임시 로컬 PostgreSQL에서 콘텐츠의 동시 실행 설명을 검증한다.

실행: PG_BIN=/path/to/postgresql/bin python3 scripts/content-postgres.test.py
외부 DB URL은 받지 않는다. TCP를 끄고 전용 임시 소켓/클러스터만 사용한다.
격리수준은 동시성 시나리오 재현, Saga 보상·Outbox 검사는 본문 SQL을 추출한다.
"""
from contextlib import ExitStack
import os
from pathlib import Path
import queue
import re
import subprocess
import tempfile
import threading
import unittest


class Session:
    def __init__(self, binary, directory):
        self.process = subprocess.Popen(
            [str(binary / 'psql'), '-X', '-qAt', '-h', directory, '-p', '55439',
             '-U', 'content_review', '-d', 'postgres', '-v', 'VERBOSITY=verbose'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, env={k: v for k, v in os.environ.items() if not k.startswith('PG')},
        )
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        self.sql("SET statement_timeout = '5s';")

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line.rstrip())
        self.lines.put(None)

    def sql(self, statement, allow_error=False):
        self.process.stdin.write(statement + '\n\\echo REVIEW_DONE\n')
        self.process.stdin.flush()
        output = []
        while True:
            line = self.lines.get(timeout=10)
            if line == 'REVIEW_DONE':
                break
            if line is None:
                raise RuntimeError('psql ended: ' + '\n'.join(output))
            output.append(line)
        result = '\n'.join(output)
        if not allow_error and 'ERROR:' in result:
            raise AssertionError(result)
        return result

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.reader.join(timeout=2)
        self.process.stdout.close()


class IsolationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.resources = ExitStack()
        cls.addClassCleanup(cls.resources.close)
        cls.binary = Path(os.environ['PG_BIN'])
        directory = cls.resources.enter_context(tempfile.TemporaryDirectory(prefix='jobstudy-pg-', dir='/tmp'))
        cls.directory = directory
        data = str(Path(directory) / 'data')
        subprocess.run([str(cls.binary / 'initdb'), '-D', data, '-U', 'content_review',
                        '--auth-local=trust', '--auth-host=reject', '--no-locale', '-E', 'UTF8'],
                       check=True, capture_output=True, text=True, timeout=30)
        # TCP disabled; the parent directory is mode 0700 and unique for this test.
        subprocess.run([str(cls.binary / 'pg_ctl'), '-D', data, '-l', directory + '/server.log',
                        '-o', f"-k {directory} -p 55439 -c listen_addresses=''", '-w', 'start'],
                       check=True, capture_output=True, text=True, timeout=30)
        cls.resources.callback(subprocess.run,
                               [str(cls.binary / 'pg_ctl'), '-D', data, '-m', 'fast', '-w', 'stop'],
                               check=True, capture_output=True, timeout=30)
        print(subprocess.check_output([str(cls.binary / 'postgres'), '--version'], text=True).strip())

    def setUp(self):
        self.a = Session(self.binary, self.directory)
        self.addCleanup(self.a.close)
        self.b = Session(self.binary, self.directory)
        self.addCleanup(self.b.close)
        self.a.sql('DROP VIEW IF EXISTS inventory_entry; DROP TABLE IF EXISTS inventory_transfer, sequence_demo; DROP TABLE IF EXISTS reservation, stock, outbox, saga_state; DROP TABLE IF EXISTS duty; CREATE TABLE duty (id int PRIMARY KEY, active boolean NOT NULL); '
                   'INSERT INTO duty VALUES (1, true), (2, true);')

    def test_read_committed_refreshes_snapshot(self):
        self.a.sql('BEGIN ISOLATION LEVEL READ COMMITTED;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '2')
        self.b.sql('UPDATE duty SET active=false WHERE id=2;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '1')
        self.a.sql('COMMIT;')

    def test_repeatable_read_keeps_snapshot_and_rejects_changed_row(self):
        self.a.sql('BEGIN ISOLATION LEVEL REPEATABLE READ;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '2')
        self.b.sql('UPDATE duty SET active=false WHERE id=2;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '2')
        result = self.a.sql('UPDATE duty SET active=true WHERE id=2;', allow_error=True)
        self.assertIn('40001', result)
        self.a.sql('ROLLBACK;')

    def test_repeatable_read_allows_write_skew(self):
        self._start_duty_decisions('REPEATABLE READ')
        self.a.sql('UPDATE duty SET active=false WHERE id=1; COMMIT;')
        self.b.sql('UPDATE duty SET active=false WHERE id=2; COMMIT;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '0')

    def test_serializable_rejects_skew_and_retry_rechecks_condition(self):
        self._start_duty_decisions('SERIALIZABLE')
        self.a.sql('UPDATE duty SET active=false WHERE id=1; COMMIT;')
        result = self.b.sql('UPDATE duty SET active=false WHERE id=2; COMMIT;', allow_error=True)
        self.assertIn('40001', result)
        self.b.sql('BEGIN ISOLATION LEVEL SERIALIZABLE;')
        # Retry the decision, not just the failed UPDATE: the last worker stays on duty.
        count = int(self.b.sql('SELECT count(*) FROM duty WHERE active;'))
        self.assertEqual(count, 1)
        if count > 1:
            self.b.sql('UPDATE duty SET active=false WHERE id=2;')
        self.b.sql('COMMIT;')
        self.assertEqual(self.a.sql('SELECT count(*) FROM duty WHERE active;'), '1')

    def test_compensation_from_card_restores_stock_once(self):
        self.a.sql("CREATE TABLE stock (sku_id int PRIMARY KEY, available int NOT NULL); "
                   "CREATE TABLE reservation (id int PRIMARY KEY, sku_id int REFERENCES stock, "
                   "qty int NOT NULL CHECK (qty > 0), state text NOT NULL); "
                   "INSERT INTO stock VALUES (1, 8); "
                   "INSERT INTO reservation VALUES (42, 1, 2, 'RESERVED');")
        sql = self._card_sql('backend-architecture-07-interview-saga', 'WITH released AS')
        sql = sql.replace(':reservation_id', '42')
        self.a.sql(sql)
        self.b.sql(sql)
        self.assertEqual(self.a.sql('SELECT available FROM stock WHERE sku_id=1;'), '10')
        self.assertEqual(self.a.sql('SELECT state FROM reservation WHERE id=42;'), 'RELEASED')

    def test_saga_state_and_next_command_rollback_together(self):
        self.a.sql("CREATE TABLE saga_state (saga_id int PRIMARY KEY, state text, version int); "
                   "CREATE TABLE outbox (command_id text UNIQUE, saga_id int, command_type text); "
                   "INSERT INTO saga_state VALUES (42, 'AUTHORIZING', 1); "
                   "INSERT INTO outbox VALUES ('next-42', 42, 'PREPARE_SHIPMENT');")
        sql = self._card_sql('backend-architecture-04-saga', 'WITH advanced AS')
        sql = sql.replace(':saga_id', '42').replace(':expected_version', '1')
        sql = sql.replace(':next_command_id', "'next-42'")
        self.assertIn('23505', self.a.sql(sql, allow_error=True))
        self.assertEqual(self.a.sql('SELECT state, version FROM saga_state;'), 'AUTHORIZING|1')
        self.a.sql('DELETE FROM outbox;')
        self.a.sql(sql)
        self.b.sql(sql)  # Duplicate result must not create another command.
        self.assertEqual(self.a.sql('SELECT state, version FROM saga_state;'), 'READY|2')
        self.assertEqual(self.a.sql('SELECT count(*) FROM outbox;'), '1')

    def test_ledger_card_balances_and_rejects_duplicate_transaction(self):
        self.a.sql(self._card_sql('logistics-11-inventory-ledger', 'CREATE TABLE inventory_transfer'))
        insert = "INSERT INTO inventory_transfer(transaction_id,business_key,sku_id,owner_id,uom," \
                 "from_account,to_account,quantity,occurred_at,reason) VALUES " \
                 "('00000000-0000-0000-0000-000000000001','move-42','sku-1','owner-1','EA'," \
                 "'A:AVAILABLE','IN_TRANSIT',10,now(),'TRANSFER');"
        self.a.sql(insert)
        self.assertEqual(self.a.sql('SELECT count(*), sum(quantity_delta) FROM inventory_entry;'), '2|0.000')
        self.assertIn('23505', self.b.sql(insert, allow_error=True))
        self.assertEqual(self.a.sql('SELECT sum(quantity_delta) FROM inventory_entry;'), '0.000')
        invalid = insert.replace('000000000001', '000000000002').replace('move-42', 'move-43')
        invalid = invalid.replace("'IN_TRANSIT',10", "'IN_TRANSIT',-10")
        self.assertIn('23514', self.a.sql(invalid, allow_error=True))
        self.assertEqual(self.a.sql('SELECT count(*) FROM inventory_transfer;'), '1')

    def test_sequence_watermark_misses_late_commit(self):
        self.a.sql('CREATE TABLE sequence_demo(id BIGSERIAL PRIMARY KEY, qty int NOT NULL); BEGIN;')
        self.assertEqual(self.a.sql('INSERT INTO sequence_demo(qty) VALUES (10) RETURNING id;'), '1')
        self.assertEqual(self.b.sql('INSERT INTO sequence_demo(qty) VALUES (20) RETURNING id;'), '2')
        self.assertEqual(self.b.sql('SELECT max(id), sum(qty) FROM sequence_demo;'), '2|20')
        self.a.sql('COMMIT;')
        self.assertEqual(self.b.sql('SELECT count(*) FROM sequence_demo WHERE id > 2;'), '0')
        self.assertEqual(self.b.sql('SELECT sum(qty) FROM sequence_demo;'), '30')

    @staticmethod
    def _card_sql(slug, marker):
        source = (Path(__file__).resolve().parents[1] /
                  'apps/api/src/main/resources/content' / (slug + '.md')).read_text()
        blocks = [block for block in re.findall(r'```sql\n(.*?)\n```', source, re.S)
                  if marker in block]
        if len(blocks) != 1:
            raise AssertionError(f'{slug}: expected one SQL block with {marker}')
        return blocks[0]

    def _start_duty_decisions(self, isolation):
        for session in (self.a, self.b):
            session.sql(f'BEGIN ISOLATION LEVEL {isolation};')
            # Both decisions see enough workers before either writes.
            self.assertGreater(int(session.sql('SELECT count(*) FROM duty WHERE active;')), 1)


if __name__ == '__main__':
    unittest.main()
