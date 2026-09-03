-- argv: play | pause | playpause | next | previous | stop
on run argv
    set cmd to item 1 of argv
    tell application "iTunes"
        if cmd is "play" then
            play
        else if cmd is "pause" then
            pause
        else if cmd is "playpause" then
            playpause
        else if cmd is "next" then
            next track
        else if cmd is "previous" then
            previous track
        else if cmd is "stop" then
            stop
        else
            error "unknown player command: " & cmd
        end if
    end tell
    return "ok"
end run
