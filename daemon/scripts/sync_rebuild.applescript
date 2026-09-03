-- argv: <managed playlist name> <spec file> [replace|append]
--
-- Rewrites one app-owned playlist to exactly the user's selection, so that a
-- device set to sync only this playlist syncs exactly what the app says.
--
-- iTunes exposes none of its own sync selection to scripting and its window
-- has no accessible controls, so the selection cannot be read or set. Playlist
-- membership, however, is fully scriptable and fast: a whole list of tracks
-- crosses in one Apple Event (491 tracks in about a second), and `whose`
-- filters run server-side in iTunes. So the app keeps the selection itself and
-- projects it onto this playlist.
--
-- The spec file is UTF-8, one selection per line, tab separated:
--   playlist<tab>Best of 2007-2011
--   artist<tab>Adele
--   genre<tab>Comedy
--   album<tab>Adele<tab>21
--
-- A track matching two selections is added twice; the playlist shows it twice
-- but the device still receives one copy, so it is left alone rather than paying
-- for a per-track de-duplication pass.
on run argv
    set plName to (item 1 of argv) as text
    set specPath to (item 2 of argv) as text
    -- The caller feeds the spec in chunks: one huge osascript run with a few
    -- thousand compound `whose` filters gets killed part way through, leaving
    -- a half-built playlist. "replace" clears first, "append" adds to it.
    set mode to "replace"
    if (count of argv) > 2 then set mode to (item 3 of argv) as text
    -- Read outside the iTunes tell block: `POSIX file` gets dispatched to
    -- iTunes inside one and fails.
    set specText to my readUTF8(specPath)
    -- `lines` is a reserved word (a property of text), as are `kind`,
    -- `missing` and `removed`. `paragraphs` splits on line breaks properly.
    set specLines to paragraphs of specText
    set added to 0
    tell application "iTunes"
        set lib to library playlist 1
        set target to missing value
        repeat with p in user playlists
            if (name of p) is plName then set target to p
        end repeat
        if target is missing value then
            set target to (make new user playlist with properties {name:plName})
        end if
        if mode is "replace" then
            -- Start from empty so the playlist ends up exactly the selection.
            try
                delete every track of target
            end try
        end if
        repeat with ln in specLines
            set cols to my splitText(ln as text, tab)
            if (count of cols) > 1 then
                set selKind to item 1 of cols
                set v1 to item 2 of cols
                try
                    if selKind is "playlist" then
                        repeat with sp in user playlists
                            if (name of sp) is v1 then
                                duplicate (every track of sp) to target
                            end if
                        end repeat
                    else if selKind is "artist" then
                        duplicate (every track of lib whose artist is v1) to target
                    else if selKind is "albumartist" then
                        duplicate (every track of lib whose album artist is v1) to target
                    else if selKind is "genre" then
                        duplicate (every track of lib whose genre is v1) to target
                    else if selKind is "album" then
                        if (count of cols) > 2 then
                            set v2 to item 3 of cols
                            duplicate (every track of lib whose album is v2 and artist is v1) to target
                        else
                            duplicate (every track of lib whose album is v1) to target
                        end if
                    end if
                end try
            end if
        end repeat
        set added to (count of tracks of target)
    end tell
    return (added as text)
end run

on readUTF8(p)
    return (read (POSIX file p as alias) as «class utf8»)
end readUTF8

-- AppleScript has no split; text item delimiters do the job.
on splitText(t, delim)
    set od to AppleScript's text item delimiters
    set AppleScript's text item delimiters to delim
    set parts to every text item of t
    set AppleScript's text item delimiters to od
    return parts
end splitText
