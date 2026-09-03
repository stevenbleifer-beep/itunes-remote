-- argv: seconds
on run argv
    tell application "iTunes"
        set player position to (item 1 of argv as number)
        return player position
    end tell
end run
