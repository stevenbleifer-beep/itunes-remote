-- argv: imagePath imageClass trackPid1 [trackPid2 ...]
-- imageClass is JPEG or PNGf: the four-character class the image data is
-- read as. The same picture goes on every track listed — an album at a
-- time is the usual case. Any artwork already on a track is replaced.
--
-- Output per track: <pid> <"ok"|"error"> [message], records split by ASCII 30.
on run argv
    set US to character id 31
    set RS to character id 30
    set imagePath to (item 1 of argv) as text
    set imageClass to (item 2 of argv) as text
    set pids to items 3 thru -1 of argv
    -- Read outside the iTunes tell block: `POSIX file` gets dispatched to
    -- iTunes inside one and fails.
    if imageClass is "PNGf" then
        set picData to my readPNG(imagePath)
    else
        set picData to my readJPEG(imagePath)
    end if
    set out to ""
    tell application "iTunes"
        repeat with p in pids
            set pid to p as text
            try
                set t to first track of library playlist 1 whose persistent ID is pid
                if (persistent ID of t) is not pid then error "persistent ID read back wrong"
                if (count of artworks of t) > 0 then
                    delete every artwork of t
                end if
                set data of artwork 1 of t to picData
                set out to out & pid & US & "ok" & RS
            on error e
                set out to out & pid & US & "error" & US & e & RS
            end try
        end repeat
    end tell
    return out
end run

on readJPEG(p)
    return (read (POSIX file p as alias) as «class JPEG»)
end readJPEG

on readPNG(p)
    return (read (POSIX file p as alias) as «class PNGf»)
end readPNG
