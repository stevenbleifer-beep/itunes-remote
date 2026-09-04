-- Reads one track's lyrics. They live only inside iTunes (and the file),
-- never in the XML, so the Get Info sheet asks for them on demand.
--
-- argv: <persistentID>
-- Output, fields separated by ASCII 31:
--     <persistentID> "ok" <lyrics>
--     <persistentID> "error" <message>

on run argv
    set US to character id 31
    set pid to (item 1 of argv) as text
    try
        tell application "iTunes"
            set t to first track of library playlist 1 whose persistent ID is pid
            set confirmed to persistent ID of t
            set lyricText to lyrics of t
        end tell
        if confirmed is not pid then error "persistent ID read back as " & confirmed
        return pid & US & "ok" & US & lyricText
    on error e
        return pid & US & "error" & US & e
    end try
end run
