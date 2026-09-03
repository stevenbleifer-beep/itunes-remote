-- argv: device names; sets the current AirPlay devices to exactly these
on run argv
    tell application "iTunes"
        set devs to {}
        repeat with n in argv
            set end of devs to (first AirPlay device whose name is (n as text))
        end repeat
        set current AirPlay devices to devs
        return "ok"
    end tell
end run
