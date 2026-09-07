-- argv: <stream URL> <persistent ID of the URL track made for this address earlier, or ""> <persistent ID of the app's previous station's URL track, or ""> [<station name>]
--
-- Tunes iTunes to a live stream. `open location` is the only way iTunes'
-- dictionary has to play a stream, and it adds a URL track to the library
-- every time it is called. So the daemon remembers which URL track each
-- address got, and this script plays that track again when there is one —
-- by persistent ID, which is a fast lookup; searching URL tracks by address
-- takes the best part of a minute over 1,800 of them. Once the new station
-- is playing, the URL track the app made for the previous one is deleted,
-- so the library carries at most one of the app's stations at a time. Only
-- URL tracks the app itself made are ever deleted, by the ID it was given.
--
-- Returns the URL track's persistent ID and name. A stream iTunes cannot
-- open errors here; one it opens but never receives (no network on this
-- Mac) sits at position 0, which the app watches for.
on run argv
    set US to character id 31
    set u to (item 1 of argv) as text
    set known to ""
    set previous to ""
    if (count of argv) > 1 then set known to (item 2 of argv) as text
    if (count of argv) > 2 then set previous to (item 3 of argv) as text
    set stationName to ""
    if (count of argv) > 3 then set stationName to (item 4 of argv) as text
    tell application "iTunes"
        set played to false
        if known is not "" then
            try
                play (first URL track of library playlist 1 whose persistent ID is known)
                set played to true
            end try
        end if
        if not played then open location u
        delay 0.5
        set pid to ""
        set nm to ""
        try
            -- What is current has to be the stream asked for: a stream iTunes
            -- could not open leaves whatever was there before (paused, even).
            if (class of current track) is URL track and (address of current track) is u then
                set pid to persistent ID of current track
                -- iTunes names the entry after the last part of the URL
                -- ("stream"); the station's own name is what the display wants.
                if stationName is not "" then
                    try
                        set name of current track to stationName
                    end try
                end if
                set nm to name of current track
            end if
        end try
        if previous is not "" and previous is not pid then
            try
                delete (first URL track of library playlist 1 whose persistent ID is previous)
            end try
        end if
        return pid & US & nm
    end tell
end run
