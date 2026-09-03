-- Bulk metadata write.
--
-- argv: <fieldCount> <field1> <value1> ... <fieldN> <valueN> <pid1> <pid2> ...
-- Values always arrive as separate argv items, never concatenated into the
-- script, so a track title containing a quote cannot break or inject anything.
--
-- Output, one record per track separated by ASCII 30, fields by ASCII 31:
--     <persistentID> <"ok"|"error"> <old1> <old2> ... <oldN>
--     <persistentID> "error" <message>
--
-- Every track is looked up by persistent ID and its persistent ID is read back
-- before anything is written, so a stale identifier cannot tag the wrong song.

on setField(t, fn, fv)
    tell application "iTunes"
        if fn is "name" then
            set old to name of t
            set name of t to fv
        else if fn is "artist" then
            set old to artist of t
            set artist of t to fv
        else if fn is "album" then
            set old to album of t
            set album of t to fv
        else if fn is "album artist" then
            set old to album artist of t
            set album artist of t to fv
        else if fn is "genre" then
            set old to genre of t
            set genre of t to fv
        else if fn is "composer" then
            set old to composer of t
            set composer of t to fv
        else if fn is "year" then
            set old to (year of t) as text
            set year of t to (fv as integer)
        else if fn is "track number" then
            set old to (track number of t) as text
            set track number of t to (fv as integer)
        else if fn is "disc number" then
            set old to (disc number of t) as text
            set disc number of t to (fv as integer)
        else if fn is "compilation" then
            set old to (compilation of t) as text
            set compilation of t to (fv is "true")
        else
            error "unsupported field: " & fn
        end if
    end tell
    return old as text
end setField

on run argv
    set US to character id 31
    set RS to character id 30
    set nf to (item 1 of argv) as integer

    set fieldNames to {}
    set fieldValues to {}
    repeat with i from 1 to nf
        set end of fieldNames to (item (i * 2) of argv) as text
        set end of fieldValues to (item (i * 2 + 1) of argv) as text
    end repeat

    set pids to items (nf * 2 + 2) thru -1 of argv
    set out to ""

    repeat with p in pids
        set pid to p as text
        try
            tell application "iTunes"
                set t to first track of library playlist 1 whose persistent ID is pid
                set confirmed to persistent ID of t
            end tell
            if confirmed is not pid then
                error "persistent ID read back as " & confirmed
            end if
            set olds to ""
            repeat with i from 1 to nf
                set olds to olds & US & my setField(t, item i of fieldNames, item i of fieldValues)
            end repeat
            set out to out & pid & US & "ok" & olds & RS
        on error e
            set out to out & pid & US & "error" & US & e & RS
        end try
    end repeat
    return out
end run
