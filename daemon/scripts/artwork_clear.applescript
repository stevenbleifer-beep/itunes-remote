-- argv: trackPid1 [trackPid2 ...]. Removes every artwork from each track.
-- Output per track: <pid> <"ok"|"error"> [message], records split by ASCII 30.
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "iTunes"
        repeat with p in argv
            set pid to p as text
            try
                set t to first track of library playlist 1 whose persistent ID is pid
                if (persistent ID of t) is not pid then error "persistent ID read back wrong"
                delete every artwork of t
                set out to out & pid & US & "ok" & RS
            on error e
                set out to out & pid & US & "error" & US & e & RS
            end try
        end repeat
    end tell
    return out
end run
