import tempfile
import unittest
from pathlib import Path
from create_update_feed import validate_feed

class UpdateFeedTests(unittest.TestCase):
    def test_feed_binds_version_immutable_url_archive_length_and_embedded_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); dmg=root/'OKVideoMac-0.8.1.dmg'; dmg.write_bytes(b'fixture')
            feed=root/'appcast.xml'
            valid='''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>134</sparkle:version><sparkle:shortVersionString>0.8.1</sparkle:shortVersionString><description>Notes</description><enclosure url="https://github.com/yaolin-dev/OKVideoMac/releases/download/v0.8.1/OKVideoMac-0.8.1.dmg" length="7" sparkle:edSignature="fixture-signature"/></item></channel></rss>'''
            feed.write_text(valid)
            self.assertEqual(validate_feed(feed,dmg,'0.8.1','134'),'fixture-signature')
            for bad in [valid.replace('>134<','>133<'),valid.replace('>0.8.1<','>0.8.0<'),
                        valid.replace('/download/v0.8.1/','/latest/download/'),
                        valid.replace('length="7"','length="8"'),
                        valid.replace('sparkle:edSignature="fixture-signature"',''),
                        valid.replace('<description>Notes</description>',''),
                        valid.replace('</item>','<sparkle:releaseNotesLink>http://example.org/notes</sparkle:releaseNotesLink></item>'),
                        valid.replace('<item>','<item/><item>')]:
                with self.subTest(xml=bad):
                    feed.write_text(bad)
                    with self.assertRaises(ValueError):validate_feed(feed,dmg,'0.8.1','134')
