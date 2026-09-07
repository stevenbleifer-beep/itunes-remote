-- argv: play | pause | playpause | next | previous | stop
--
-- `play` and `playpause` with nothing current are refused: iTunes would
-- play whatever is selected in its own window, and take that window's
-- playlist or library as a standing source that it resumes after every
-- track the app plays by reference — for days, until it is played out.
-- The app starts songs with play_track and queue_play instead.
on run argv
    set cmd to item 1 of argv
    tell application "iTunes"
        if cmd is "play" or cmd is "playpause" then
            if player state is stopped then
                set hasTrack to false
                try
                    set hasTrack to (exists current track)
                end try
                if not hasTrack then return "ignored: nothing current"
            end if
        end if
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
