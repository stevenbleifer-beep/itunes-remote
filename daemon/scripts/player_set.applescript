-- argv: shuffle true|false   |   repeat off|one|all
on run argv
    set what to item 1 of argv
    set v to item 2 of argv
    tell application "iTunes"
        if what is "shuffle" then
            set shuffle enabled to (v is "true")
            if shuffle enabled then return "true"
            return "false"
        else if what is "repeat" then
            if v is "one" then
                set song repeat to one
            else if v is "all" then
                set song repeat to all
            else
                set song repeat to off
            end if
            return v
        end if
        error "unknown setting: " & what
    end tell
end run
