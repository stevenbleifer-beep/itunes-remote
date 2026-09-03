-- argv: <playlistPersistentID> <new name>
on run argv
    set plPid to (item 1 of argv) as text
    set newName to (item 2 of argv) as text
    tell application "iTunes"
        set pl to first user playlist whose persistent ID is plPid
        set old to name of pl
        set name of pl to newName
        return old
    end tell
end run
