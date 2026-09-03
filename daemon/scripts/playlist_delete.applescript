-- argv: <playlistPersistentID>
--
-- Only ever resolves a *user* playlist, which cannot name the library, so this
-- removes a playlist and never a track or a file.
on run argv
    set plPid to (item 1 of argv) as text
    tell application "iTunes"
        set pl to first user playlist whose persistent ID is plPid
        set nm to name of pl
        delete pl
        return nm
    end tell
end run
