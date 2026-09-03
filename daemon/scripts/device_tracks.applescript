-- argv: <source name> <playlist name> <limit>. The tracks actually on a
-- device, four fields each, for the device page's "On My Device" lists.
--
-- Fields are joined with a delimiter and split by the caller rather than read
-- one at a time: indexing a 23,000-element AppleScript list is O(n^2).
on run argv
    set devName to (item 1 of argv) as text
    set plName to (item 2 of argv) as text
    set lim to (item 3 of argv) as integer
    set US to character id 31
    set od to AppleScript's text item delimiters
    tell application "iTunes"
        set dev to missing value
        repeat with s in sources
            if (name of s) is devName then set dev to s
        end repeat
        if dev is missing value then error "no source named " & devName number -1728
        set pl to missing value
        repeat with p in playlists of dev
            if (name of p) is plName then set pl to p
        end repeat
        if pl is missing value then error "no playlist named " & plName number -1728
        set n to (count of tracks of pl)
        if n > lim then set n to lim
        if n is 0 then
            set AppleScript's text item delimiters to od
            return ""
        end if
        -- `name of tracks 1 thru n of pl` is the plural form iTunes answers in
        -- one event. Binding the range to a variable first gives a list of
        -- references instead, and `name of` that list fails with -1700.
        set AppleScript's text item delimiters to US
        set ns to (name of tracks 1 thru n of pl) as text
        set ar to (artist of tracks 1 thru n of pl) as text
        set al to (album of tracks 1 thru n of pl) as text
        set tm to (duration of tracks 1 thru n of pl) as text
    end tell
    set AppleScript's text item delimiters to (character id 30)
    set out to {ns, ar, al, tm} as text
    set AppleScript's text item delimiters to od
    return out
end run
