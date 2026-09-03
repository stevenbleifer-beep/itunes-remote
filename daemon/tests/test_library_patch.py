"""Regression tests for in-memory patching.

Run from daemon/:  python3 -m unittest discover -v

The test that matters is `test_reader_never_sees_a_short_library`. Reads run on
other threads without a lock, so patching must never sort `order` in place:
CPython empties a list while `list.sort` runs, and a reader iterating it at
that moment sees zero tracks. That produced a track table that flashed empty
during a bulk edit.
"""

import os
import plistlib
import tempfile
import threading
import unittest
from datetime import datetime

from itunes_remote.library import Library, LibraryStore

TRACK_COUNT = 20000


def write_fixture(path, count=TRACK_COUNT, when=None):
    """A synthetic library XML shaped like iTunes writes one."""
    tracks = {}
    for i in range(1, count + 1):
        tracks[str(i)] = {
            "Track ID": i,
            "Persistent ID": "%016X" % i,
            "Track Type": "File",
            "Kind": "AAC audio file",
            "Name": "Track %05d" % (count - i),      # deliberately not pre-sorted
            "Artist": "Artist %03d" % (i % 500),
            "Album": "Album %03d" % (i % 900),
            "Genre": "Rock" if i % 2 else "Jazz",
            "Year": 1960 + (i % 60),
            "Track Number": (i % 20) + 1,
            "Total Time": 200000,
            "Size": 5000000,
            "Location": "file:///tmp/track%d.m4a" % i,
        }
    plist = {
        "Major Version": 1,
        "Minor Version": 1,
        "Application Version": "12.9.5.5",
        "Date": when or datetime(2020, 1, 1, 0, 0, 0),
        "Library Persistent ID": "0000000000000001",
        "Tracks": tracks,
        "Playlists": [],
    }
    with open(path, "wb") as f:
        plistlib.dump(plist, f)


class FixtureCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fd, cls.path = tempfile.mkstemp(suffix=".xml", prefix="itr-test-")
        os.close(fd)
        write_fixture(cls.path)

    @classmethod
    def tearDownClass(cls):
        try:
            os.unlink(cls.path)
        except OSError:
            pass


class TestPatchConcurrency(FixtureCase):

    def test_reader_never_sees_a_short_library(self):
        """The regression. Readers must always see every track."""
        store = LibraryStore(self.path)
        store.load()
        pids = [t.persistent_id for t in store.lib.order[:400]]

        bad = []
        reads = [0]
        stop = threading.Event()

        def reader():
            while not stop.is_set():
                total = store.lib.query(limit=1)["total"]
                reads[0] += 1
                if total != TRACK_COUNT:
                    bad.append(total)

        t = threading.Thread(target=reader)
        t.start()
        try:
            # Album is a sort field, so every one of these forces a re-sort.
            for n, pid in enumerate(pids):
                store.patch(pid, {"album": "Renamed %04d" % n})
        finally:
            stop.set()
            t.join()

        self.assertGreater(reads[0], 100, "reader did not get enough reads to be meaningful")
        self.assertEqual(bad, [], "reader saw %d short reads, e.g. %s" % (len(bad), bad[:5]))

    def test_reader_never_sees_a_short_library_during_a_batch(self):
        store = LibraryStore(self.path)
        store.load()
        batch = {t.persistent_id: {"album": "Batched"} for t in store.lib.order[:300]}

        bad = []
        stop = threading.Event()

        def reader():
            while not stop.is_set():
                if store.lib.query(limit=1)["total"] != TRACK_COUNT:
                    bad.append(1)

        t = threading.Thread(target=reader)
        t.start()
        try:
            for _ in range(40):
                store.patch_many(batch)
        finally:
            stop.set()
            t.join()
        self.assertEqual(bad, [])


class TestPatchBehaviour(FixtureCase):

    def setUp(self):
        self.store = LibraryStore(self.path)
        self.store.load()
        self.lib = self.store.lib

    def test_genre_edit_does_not_resort(self):
        """Genre is not in sort_key, so the bulk genre edit must skip sorting."""
        before = self.lib.order
        pid = before[0].persistent_id
        self.store.patch(pid, {"genre": "Post-Punk"})
        self.assertIs(self.lib.order, before, "a genre-only edit rebuilt the order list")
        self.assertEqual(self.lib.tracks[pid].genre, "Post-Punk")

    def test_sort_field_edit_rebinds_and_reorders(self):
        before = self.lib.order
        pid = before[-1].persistent_id
        self.store.patch(pid, {"artist": "AAA First"})
        self.assertIsNot(self.lib.order, before, "a sort-field edit did not rebuild the order list")
        self.assertEqual(len(self.lib.order), TRACK_COUNT)
        keys = [t.sort_key for t in self.lib.order]
        self.assertEqual(keys, sorted(keys), "order is not sorted after a sort-field edit")
        self.assertEqual(self.lib.order[0].persistent_id, pid)

    def test_returns_old_values(self):
        pid = self.lib.order[0].persistent_id
        was = self.lib.tracks[pid].genre
        old = self.store.patch(pid, {"genre": "Changed"})
        self.assertEqual(old, {"genre": was})

    def test_batch_is_atomic_on_a_bad_field(self):
        good = self.lib.order[0].persistent_id
        bad = self.lib.order[1].persistent_id
        genre_before = self.lib.tracks[good].genre
        with self.assertRaises(ValueError):
            self.store.patch_many({
                good: {"genre": "Should Not Stick"},
                bad: {"location": "/etc/passwd"},
            })
        self.assertEqual(self.lib.tracks[good].genre, genre_before,
                         "a rejected batch applied part of its changes")

    def test_batch_is_atomic_on_an_unknown_track(self):
        good = self.lib.order[0].persistent_id
        genre_before = self.lib.tracks[good].genre
        with self.assertRaises(KeyError):
            self.store.patch_many({good: {"genre": "Nope"}, "DEADBEEFDEADBEEF": {"genre": "x"}})
        self.assertEqual(self.lib.tracks[good].genre, genre_before)

    def test_search_index_follows_an_edit(self):
        pid = self.lib.order[0].persistent_id
        self.store.patch(pid, {"name": "Zzzyzx Unique Title"})
        hits = self.lib.query(q="zzzyzx unique")["tracks"]
        self.assertEqual([h["persistentId"] for h in hits], [pid])

    def test_totals_stay_correct_after_a_patch(self):
        before = self.lib.query(limit=1)
        self.store.patch(self.lib.order[0].persistent_id, {"album": "Anything"})
        after = self.lib.query(limit=1)
        self.assertEqual(after["total"], before["total"])
        self.assertEqual(after["totalSize"], before["totalSize"])


class TestJournalReplay(FixtureCase):

    def test_patch_survives_a_reload_of_an_older_xml(self):
        store = LibraryStore(self.path)
        store.load()
        pid = store.lib.order[0].persistent_id
        store.patch(pid, {"genre": "Kept"})
        store._reload()   # same fixture, XML Date is 2020, patch is newer
        self.assertEqual(store.lib.tracks[pid].genre, "Kept")
        self.assertEqual(len(store.lib.order), TRACK_COUNT)

    def test_patch_is_dropped_once_the_xml_catches_up(self):
        fd, newer = tempfile.mkstemp(suffix=".xml", prefix="itr-test-newer-")
        os.close(fd)
        try:
            store = LibraryStore(newer)
            write_fixture(newer, count=200, when=datetime(2020, 1, 1))
            store.load()
            pid = store.lib.order[0].persistent_id
            store.patch(pid, {"genre": "Stale"})
            # iTunes rewrites the XML well after the patch was made.
            write_fixture(newer, count=200, when=datetime(2099, 1, 1))
            store._reload()
            self.assertNotEqual(store.lib.tracks[pid].genre, "Stale")
            self.assertEqual(store.status()["journalLength"], 0)
        finally:
            os.unlink(newer)


if __name__ == "__main__":
    unittest.main()


class BrowserSelectionTest(unittest.TestCase):
    """A browser row must select the tracks it counted.

    The Artists pane groups by the Sort Artist field but shows the display
    name, and iTunes gives every "The X" band a sort artist of "X". Matching
    the click on the display name alone found nothing.
    """

    TRACKS = [
        {"Persistent ID": "AAAA000000000001", "Track ID": 1, "Name": "Cinema",
         "Artist": "The Mar\u00edas", "Sort Artist": "Mar\u00edas",
         "Album": "Superclean", "Kind": "AAC audio file", "Track Type": "File"},
        {"Persistent ID": "AAAA000000000002", "Track ID": 2, "Name": "Ride",
         "Artist": "The Beatles", "Sort Artist": "Beatles",
         "Album": "Help", "Kind": "AAC audio file", "Track Type": "File"},
    ]

    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".xml", prefix="itr-browse-")
        os.close(fd)
        plist = {
            "Major Version": 1, "Minor Version": 1,
            "Application Version": "12.9.5.5",
            "Date": datetime(2020, 1, 1),
            "Library Persistent ID": "0000000000000002",
            "Tracks": {str(t["Track ID"]): t for t in self.TRACKS},
            "Playlists": [],
        }
        with open(self.path, "wb") as f:
            plistlib.dump(plist, f)
        self.lib = Library(self.path)

    def tearDown(self):
        try:
            os.unlink(self.path)
        except OSError:
            pass

    def rows(self, **kw):
        return [t.name for t in self.lib._filter(self.lib.order, **kw)]

    def test_the_row_selects_its_tracks(self):
        for row in self.lib.facet("artist"):
            self.assertTrue(self.rows(artist=row["name"]),
                            "the row %r selected nothing" % row["name"])

    def test_the_sort_form_selects_them_too(self):
        self.assertEqual(self.rows(artist="Beatles"), ["Ride"])

    def test_accents_still_do_not_matter(self):
        self.assertEqual(self.rows(artist="The Marias"), ["Cinema"])
