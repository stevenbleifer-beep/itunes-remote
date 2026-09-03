"""Reads embedded cover art straight out of audio files. Read-only.

Handles the two containers that hold nearly everything in this library:
MPEG-4 (m4a, ALAC) `covr` atoms and MP3 ID3v2 `APIC`/`PIC` frames. Anything
else, or a file with no embedded picture, returns None so the caller can fall
back to asking iTunes for its artwork.
"""

import struct


def sniff(data):
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:4] == b"GIF8":
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def read_embedded(path):
    """Returns (mime, bytes) or None."""
    lower = path.lower()
    try:
        with open(path, "rb") as f:
            head = f.read(12)
            f.seek(0)
            if head[4:8] == b"ftyp":
                return _mp4_cover(f)
            if head[:3] == b"ID3":
                return _id3_cover(f)
            if lower.endswith((".m4a", ".m4p", ".m4b", ".mp4")):
                return _mp4_cover(f)
    except (OSError, struct.error, ValueError):
        return None
    return None


# -- MPEG-4 -------------------------------------------------------------

def _atoms(f, start, end):
    """Yields (type, payload_start, payload_end) for atoms in [start, end)."""
    pos = start
    while pos + 8 <= end:
        f.seek(pos)
        hdr = f.read(8)
        if len(hdr) < 8:
            return
        size, kind = struct.unpack(">I4s", hdr)
        header = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return
        yield kind, pos + header, pos + size
        pos += size


def _find(f, start, end, kind):
    for k, s, e in _atoms(f, start, end):
        if k == kind:
            return s, e
    return None


def _mp4_cover(f):
    f.seek(0, 2)
    size = f.tell()
    moov = _find(f, 0, size, b"moov")
    if not moov:
        return None
    udta = _find(f, moov[0], moov[1], b"udta")
    if not udta:
        return None
    meta = _find(f, udta[0], udta[1], b"meta")
    if not meta:
        return None
    ilst = _find(f, meta[0] + 4, meta[1], b"ilst")   # meta has 4 bytes of version/flags
    if not ilst:
        return None
    covr = _find(f, ilst[0], ilst[1], b"covr")
    if not covr:
        return None
    for k, s, e in _atoms(f, covr[0], covr[1]):
        if k != b"data" or e - s < 8:
            continue
        f.seek(s + 8)   # 4 bytes type/flags + 4 bytes locale
        data = f.read(e - s - 8)
        mime = sniff(data)
        if mime:
            return mime, data
    return None


# -- ID3v2 --------------------------------------------------------------

def _syncsafe(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def _unsync(data):
    return data.replace(b"\xff\x00", b"\xff")


def _id3_cover(f):
    hdr = f.read(10)
    if hdr[:3] != b"ID3":
        return None
    major = hdr[3]
    flags = hdr[5]
    tag_size = _syncsafe(hdr[6:10])
    body = f.read(tag_size)
    if flags & 0x80:   # whole-tag unsynchronisation (v2.2/2.3)
        if major >= 4:
            return None
        body = _unsync(body)
    pos = 0
    if flags & 0x40:   # extended header
        if major == 3:
            pos += 4 + struct.unpack(">I", body[:4])[0]
        elif major == 4:
            pos += _syncsafe(body[:4])
    candidates = []
    while pos < len(body):
        if major == 2:
            if pos + 6 > len(body):
                break
            fid = body[pos:pos + 3]
            if fid[0] == 0:
                break
            fsize = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5]
            fflags = 0
            hsize = 6
        else:
            if pos + 10 > len(body):
                break
            fid = body[pos:pos + 4]
            if fid[0] == 0:
                break
            raw = body[pos + 4:pos + 8]
            fsize = _syncsafe(raw) if major == 4 else struct.unpack(">I", raw)[0]
            fflags = struct.unpack(">H", body[pos + 8:pos + 10])[0]
            hsize = 10
        data = body[pos + hsize:pos + hsize + fsize]
        pos += hsize + fsize
        if fid not in (b"APIC", b"PIC"):
            continue
        if major == 4:
            if fflags & 0x0C:      # compressed or encrypted: give up on this frame
                continue
            if fflags & 0x01:      # data length indicator
                data = data[4:]
            if fflags & 0x02:
                data = _unsync(data)
        elif major == 3 and fflags & 0x00C0:
            continue
        pic = _parse_apic(data, fid == b"PIC")
        if pic:
            candidates.append(pic)
    if not candidates:
        return None
    # Front cover (type 3) first, then whatever came first.
    for ptype, mime, blob in candidates:
        if ptype == 3:
            return mime, blob
    _, mime, blob = candidates[0]
    return mime, blob


def _parse_apic(data, v22):
    if len(data) < 4:
        return None
    enc = data[0]
    i = 1
    if v22:
        i += 3   # 3-char image format
    else:
        end = data.find(b"\x00", i)
        if end < 0:
            return None
        i = end + 1
    if i >= len(data):
        return None
    ptype = data[i]
    i += 1
    if enc in (1, 2):   # UTF-16: double-null terminator on an even boundary
        j = i
        while j + 1 < len(data):
            if data[j] == 0 and data[j + 1] == 0:
                j += 2
                break
            j += 2
        i = j
    else:
        end = data.find(b"\x00", i)
        i = len(data) if end < 0 else end + 1
    blob = data[i:]
    mime = sniff(blob)
    if not mime:
        return None
    return ptype, mime, blob
