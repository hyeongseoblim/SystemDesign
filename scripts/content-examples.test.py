"""검수 카드의 실행 가능한 예제를 본문에서 읽어 회귀 검증한다."""
from itertools import product
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DistributedClockExampleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / 'apps/api/src/main/resources/content/system-design-18-distributed-clocks.md').read_text()
        blocks = re.findall(r'```python\n(.*?)\n```', source, re.S)
        cls.namespace = {}
        assert len(blocks) == 1, 'HLC 실행 예제는 하나로 유지한다'
        exec(compile(blocks[0], 'system-design-18-distributed-clocks.md', 'exec'), cls.namespace)

    def test_clock_regression_and_progress(self):
        local = self.namespace['local_event']
        self.assertEqual(local((20, 7), 10), (20, 8))
        self.assertEqual(local((20, 7), 20), (20, 8))
        self.assertEqual(local((20, 7), 21), (21, 0))

    def test_receive_counter_branches(self):
        receive = self.namespace['receive_event']
        self.assertEqual(receive((20, 9), (20, 4), 19), (20, 10))
        self.assertEqual(receive((20, 2), (19, 99), 18), (20, 3))
        self.assertEqual(receive((19, 99), (20, 2), 18), (20, 3))
        self.assertEqual(receive((20, 9), (21, 7), 22), (22, 0))

    def test_receive_follows_local_and_remote_events(self):
        receive = self.namespace['receive_event']
        for lt, lc, rt, rc, wall in product(range(4), repeat=5):
            result = receive((lt, lc), (rt, rc), wall)
            self.assertGreater(result, (lt, lc))
            self.assertGreater(result, (rt, rc))
            self.assertEqual(result[0], max(lt, rt, wall))


if __name__ == '__main__':
    unittest.main()
