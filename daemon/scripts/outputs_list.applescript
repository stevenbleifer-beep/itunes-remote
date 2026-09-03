-- One record per AirPlay device: name, kind, selected, active, available, volume
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "iTunes"
        repeat with d in AirPlay devices
            set k to "unknown"
            try
                set k to (kind of d) as text
            end try
            set v to -1
            try
                set v to sound volume of d
            end try
            set out to out & (name of d) & US & k & US & (selected of d) & US & (active of d) & US & (available of d) & US & v & RS
        end repeat
    end tell
    return out
end run
