import http.client
from pathlib import Path
from tempfile import TemporaryDirectory
import threading
import unittest

from run_media_journeys import FixtureServer


class MediaFixtureServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        root = Path(self.temp.name)
        (root/'seek').mkdir()
        (root/'seek/manifest.mpd').write_bytes(b'0123456789')
        self.server = FixtureServer(root)
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.worker.join(timeout=2)
        self.temp.cleanup()

    def request(self, path, method='GET', headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        try:
            connection.request(method, path, headers=headers or {})
            result = connection.getresponse()
            return result.status, result.read(), dict(result.getheaders())
        finally: connection.close()

    def testRangeAndHeadExerciseTheSameBytes(self):
        status, body, headers = self.request('/seek/manifest.mpd', headers={'Range':'bytes=3-5'})
        self.assertEqual((status, body, headers['Content-Range']), (206, b'345', 'bytes 3-5/10'))
        status, body, headers = self.request('/seek/manifest.mpd', method='HEAD')
        self.assertEqual((status, body, headers['Content-Length']), (200, b'', '10'))
        self.assertEqual(self.request('/seek/manifest.mpd', headers={'Range':'bytes=50-60'})[0], 416)

    def testExplicitRecoveryChangesOnlyTheFixtureFailure(self):
        self.assertEqual(self.request('/recoverable/seek/manifest.mpd')[0], 503)
        self.assertEqual(self.request('/control/recover', method='POST')[0], 204)
        self.assertEqual(self.request('/recoverable/seek/manifest.mpd')[:2], (200, b'0123456789'))

    def testUnknownAndEscapingPathsAreNotServed(self):
        for path in ['/missing', '/../outside', '/control/unknown']:
            self.assertEqual(self.request(path)[0], 404)
