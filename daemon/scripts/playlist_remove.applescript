-- argv: <playlistPersistentID> <trackPid1> <trackPid2> ...
--
-- Only ever deletes from a *user* playlist, which removes the track from that
-- playlist and leaves the library untouched. `user playlist` cannot resolve to
-- the library playlist, so this cannot delete a file by mistake.
on run argv
    set US to character id 31
    set RS to character id 30
    set plPid to (item 1 of argv) as text
    set pids to items 2 thru -1 of argv
    set out to ""
    tell application "iTunes"
        set pl to first user playlist whose persistent ID is plPid
        if (smart of pl) then error "cannot remove from a smart playlist"
        repeat with p in pids
            set pid to p as text
            try
                set t to first track of pl whose persistent ID is pid
                delete t
                set out to out & pid & US & "ok" & RS
            on error e
                set out to out & pid & US & "error" & US & e & RS
            end try
        end repeat
    end tell
    return out
end run
