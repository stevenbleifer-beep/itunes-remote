-- argv: <source name>. The artists, albums and genres actually on a device.
--
-- iTunes keeps its sync selection in its library database, where nothing
-- outside iTunes can read it. What reached the device is readable, and that is
-- what the Music pane marks. Three joined lists, one record each.
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
        set mp to missing value
        repeat with p in playlists of dev
            if ((special kind of p) as text) is "Music" then set mp to p
        end repeat
        if mp is missing value then error "no Music playlist on " & devName number -1728
        if (count of tracks of mp) is 0 then
            set AppleScript's text item delimiters to od
            return ""
        end if
        set AppleScript's text item delimiters to US
        set out to out & "artist" & US & ((artist of every track of mp) as text) & RS
        set out to out & "albumartist" & US & ((album artist of every track of mp) as text) & RS
        set out to out & "album" & US & ((album of every track of mp) as text) & RS
        set out to out & "genre" & US & ((genre of every track of mp) as text) & RS
    end tell
    set AppleScript's text item delimiters to od
    return out
end run
