-- One record per iTunes source: name, kind, freeSpace, capacity (bytes; -1 if n/a).
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "iTunes"
        repeat with s in sources
            set k to "unknown"
            try
                set k to (kind of s) as text
            end try
            set fs to -1
            set cap to -1
            try
                set fs to free space of s
                set cap to capacity of s
            end try
            set out to out & (name of s) & US & k & US & fs & US & cap & RS
        end repeat
    end tell
    return out
end run
