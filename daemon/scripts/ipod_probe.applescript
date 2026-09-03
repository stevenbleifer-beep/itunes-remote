-- SPEC section 7 probe. Lists sources; for each iPod source, sends `update`
-- and reports the verbatim result. Run only with the iPod connected and
-- recognised by iTunes (it appears in the iTunes sidebar).
on run argv
    set out to ""
    tell application "iTunes"
        set found to 0
        repeat with s in sources
            set k to "unknown"
            try
                set k to (kind of s) as text
            end try
            set out to out & "source: " & (name of s) & " [" & k & "]" & return
            if k is "iPod" then
                set found to found + 1
                try
                    update s
                    set out to out & "  update " & (name of s) & ": OK, sync started" & return
                on error e number n
                    set out to out & "  update " & (name of s) & ": FAILED " & n & " " & e & return
                end try
            end if
        end repeat
        if found is 0 then set out to out & "no iPod source; replug the iPod and check it shows in iTunes" & return
    end tell
    return out
end run
