-- argv: <source name> <persistent ID>...
-- Copies library tracks onto a device, the way dragging them onto it in
-- iTunes does.
--
-- iTunes only allows this when the device is set to "Manually manage music
-- and videos"; otherwise it refuses every copy with -54 (File permission
-- error) because the device's contents are owned by the sync. The caller
-- turns that into an explanation rather than a bare error.
on run argv
    set devName to (item 1 of argv) as text
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "iTunes"
        set dev to missing value
        repeat with s in sources
            if (name of s) is devName then set dev to s
        end repeat
        if dev is missing value then error "no source named " & devName number -1728
        set target to missing value
        repeat with p in playlists of dev
            if ((special kind of p) as text) is "Music" then set target to p
        end repeat
        if target is missing value then error "no Music playlist on " & devName number -1728
        set lib to library playlist 1 of source 1
        repeat with i from 2 to (count of argv)
            set pid to (item i of argv) as text
            try
                set t to (first file track of lib whose persistent ID is pid)
                duplicate t to target
                set out to out & pid & US & "ok" & US & (name of t) & RS
            on error e number n
                set out to out & pid & US & ("error " & n) & US & e & RS
            end try
        end repeat
    end tell
    return out
end run
