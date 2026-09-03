-- argv: <source name>. Ejects that iPod source the way the sidebar button does.
on run argv
    set n to (item 1 of argv) as text
    tell application "iTunes"
        set s to first source whose name is n and kind is iPod
        eject s
    end tell
    return "ejected"
end run
