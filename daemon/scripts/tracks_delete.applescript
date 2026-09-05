-- Deletes tracks from the library. The file stays on disk; iTunes only
-- forgets it (and drops it from every playlist).
--
-- argv: <pid1> <pid2> ...
-- Output, one record per track separated by ASCII 30, fields by ASCII 31:
--     <persistentID> "ok"
--     <persistentID> "error" <message>
--
-- Every track is found by persistent ID in the library playlist and its ID
-- is read back before the delete, so a stale identifier cannot take the
-- wrong song.
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    repeat with p in argv
        set pid to p as text
        try
            tell application "iTunes"
                set t to first track of library playlist 1 whose persistent ID is pid
                set confirmed to persistent ID of t
                if confirmed is not pid then error "persistent ID read back as " & confirmed
                delete t
            end tell
            set out to out & pid & US & "ok" & RS
        on error e
            set out to out & pid & US & "error" & US & e & RS
        end try
    end repeat
    return out
end run
