-- argv: <source name>. Everything iTunes knows about one connected device.
--
-- Records (ASCII 30) of fields (ASCII 31). First record is
--   dev, name, kind, capacity, free space
-- then one record per playlist on the device:
--   pl, name, special kind, track count, comma-joined track sizes
--
-- Sizes come back as one joined string on purpose. Summing a 23,000-element
-- AppleScript list by index is O(n^2) and took 21 s here; joining the whole
-- list with a text item delimiter and adding the numbers in Python takes
-- under a second.
on run argv
    set devName to (item 1 of argv) as text
    set US to character id 31
    set RS to character id 30
    set od to AppleScript's text item delimiters
    set out to ""
    tell application "iTunes"
        set dev to missing value
        repeat with s in sources
            if (name of s) is devName then set dev to s
        end repeat
        if dev is missing value then error "no source named " & devName number -1728
        set cap to -1
        set fs to -1
        try
            set cap to capacity of dev
            set fs to free space of dev
        end try
        set out to "dev" & US & (name of dev) & US & ((kind of dev) as text) & US & cap & US & fs & RS
        -- A sample of what is actually on the device. iTunes exposes none of
        -- its sync settings to scripting, but "convert higher bit rate songs
        -- to N kbps" leaves its fingerprint here: nothing above the cap, and
        -- a large cluster sitting exactly on it.
        try
            set mp to missing value
            repeat with p in playlists of dev
                if ((special kind of p) as text) is "Music" then set mp to p
            end repeat
            if mp is not missing value then
                set n to (count of tracks of mp)
                if n > 400 then set n to 400
                if n > 0 then
                    set AppleScript's text item delimiters to ","
                    set out to out & "br" & US & ((bit rate of tracks 1 thru n of mp) as text) & RS
                    set AppleScript's text item delimiters to od
                end if
            end if
        end try
        repeat with p in playlists of dev
            set sk to (special kind of p) as text
            set n to (count of tracks of p)
            set sizes to ""
            -- The Library playlist repeats every other playlist's tracks, so
            -- summing it would double-count the device.
            if n > 0 and sk is not "Library" and sk is not "none" then
                set AppleScript's text item delimiters to ","
                try
                    set sizes to (size of every track of p) as text
                end try
                set AppleScript's text item delimiters to od
            end if
            set out to out & "pl" & US & (name of p) & US & sk & US & n & US & sizes & RS
        end repeat
    end tell
    set AppleScript's text item delimiters to od
    return out
end run
