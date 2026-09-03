"""The on-disk artwork cache: what it stores, and when it goes stale."""

import os
import shutil
import tempfile
import unittest

from itunes_remote import artwork


class DiskCacheTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="itr-art-test-")
        self.cache = artwork.DiskCache(self.root)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_round_trip_keeps_bytes_and_type(self):
        png = b"\x89PNG\r\n\x1a\n" + b"body"
        self.cache.put("AAAA1111BBBB2222", ("image/png", png))
        self.assertEqual(self.cache.get("AAAA1111BBBB2222"), ("image/png", png))

    def test_unknown_track_is_a_plain_miss(self):
        self.assertIsNone(self.cache.get("NOTHINGHERE00000"))

    def test_no_artwork_is_recorded_so_itunes_is_not_asked_twice(self):
        self.cache.put("CCCC3333DDDD4444", None)
        self.assertIs(self.cache.get("CCCC3333DDDD4444"), artwork.MISS)

    def test_a_cover_older_than_the_track_is_stale(self):
        pid = "EEEE5555FFFF6666"
        self.cache.put(pid, ("image/jpeg", b"\xff\xd8\xff old"))
        path = os.path.join(self.root, pid[:2], pid + ".jpg")
        os.utime(path, (1000, 1000))
        self.assertIsNone(self.cache.get(pid, not_before=2000))
        self.assertIsNotNone(self.cache.get(pid, not_before=500))

    def test_changing_format_removes_the_old_file(self):
        pid = "1111222233334444"
        self.cache.put(pid, ("image/png", b"\x89PNG\r\n\x1a\n"))
        self.cache.put(pid, ("image/jpeg", b"\xff\xd8\xffnew"))
        d = os.path.join(self.root, pid[:2])
        self.assertEqual(sorted(os.listdir(d)), [pid + ".jpg"])
        self.assertEqual(self.cache.get(pid)[0], "image/jpeg")

    def test_a_later_cover_clears_an_earlier_miss(self):
        pid = "5555666677778888"
        self.cache.put(pid, None)
        self.cache.put(pid, ("image/png", b"\x89PNG\r\n\x1a\nx"))
        self.assertEqual(self.cache.get(pid)[0], "image/png")
        self.assertEqual(os.listdir(os.path.join(self.root, pid[:2])), [pid + ".png"])

    def test_writes_leave_no_temporary_files_behind(self):
        self.cache.put("9999AAAABBBBCCCC", ("image/png", b"\x89PNG\r\n\x1a\n"))
        names = os.listdir(os.path.join(self.root, "99"))
        self.assertEqual([n for n in names if n.startswith(".tmp-")], [])

    def test_an_unwritable_root_does_not_raise(self):
        cache = artwork.DiskCache("/dev/null/nowhere")
        cache.put("AAAABBBBCCCCDDDD", ("image/png", b"\x89PNG\r\n\x1a\n"))
        self.assertIsNone(cache.get("AAAABBBBCCCCDDDD"))


if __name__ == "__main__":
    unittest.main()
