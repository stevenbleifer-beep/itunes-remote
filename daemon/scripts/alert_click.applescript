-- argv: <button name>. Clicks that button on iTunes' open dialog, so an alert
-- can be cleared from the remote instead of screen sharing. Only ever touches
-- a sheet or a window whose subrole is AXDialog, and only a button that
-- already exists on it.
on run argv
    set target to (item 1 of argv) as text
    tell application "System Events"
        tell process "iTunes"
            repeat with w in windows
                try
                    repeat with sh in sheets of w
                        return my clickIn(sh, target)
                    end repeat
                end try
                try
                    if subrole of w is "AXDialog" then return my clickIn(w, target)
                end try
            end repeat
        end tell
    end tell
    error "iTunes is not showing a dialog"
end run

on clickIn(w, target)
    tell application "System Events"
        repeat with b in buttons of w
            if (name of b) as text is target then
                click b
                return "clicked"
            end if
        end repeat
    end tell
    error "no button named " & target & " on the dialog"
end clickIn
