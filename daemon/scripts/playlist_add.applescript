-- argv: <playlistPersistentID> <trackPid1> <trackPid2> ...
--
-- Uses `duplicate` rather than `add`. `add` is for importing files that are
-- not in the library yet; using it on an existing track re-imports the file
-- and leaves a second copy in the library.
--
-- Output per track: <pid> <"ok"|"error"> [message], records split by ASCII 30.
on run argv
    set US to character id 31
    set RS to character id 30
    set plPid to (item 1 of argv) as text
    set pids to items 2 thru -1 of argv
    set out to ""
    tell application "iTunes"
        set pl to first user playlist whose persistent ID is plPid
        if (smart of pl) then error "cannot add to a smart playlist"
        repeat with p in pids
            set pid to p as text
            try
                set t to first track of library playlist 1 whose persistent ID is pid
                if (persistent ID of t) is not pid then error "persistent ID read back wrong"
                duplicate t to pl
                set out to out & pid & US & "ok" & RS
            on error e
                set out to out & pid & US & "error" & US & e & RS
            end try
        end repeat
    end tell
    return out
end run
