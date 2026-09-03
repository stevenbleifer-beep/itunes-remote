-- argv: <source name>. Sends `update` to that iPod source. iTunes gives no
-- progress, so the caller shows "sync started" and nothing more.
on run argv
    set n to (item 1 of argv) as text
    tell application "iTunes"
        set s to first source whose name is n and kind is iPod
        update s
    end tell
    return "started"
end run
