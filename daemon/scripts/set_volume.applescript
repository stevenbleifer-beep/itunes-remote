-- argv: 0..100
on run argv
    tell application "iTunes"
        set sound volume to (item 1 of argv as integer)
        return sound volume
    end tell
end run
