-- argv: trackPersistentID outPath. Writes the first artwork's raw bytes to outPath.
on run argv
    set pid to item 1 of argv
    set outPath to item 2 of argv
    tell application "iTunes"
        set t to first track of library playlist 1 whose persistent ID is pid
        if (count of artworks of t) is 0 then return "none"
        set d to raw data of artwork 1 of t
    end tell
    set f to open for access (POSIX file outPath) with write permission
    try
        set eof f to 0
        write d to f
        close access f
    on error e
        close access f
        error e
    end try
    return "ok"
end run
