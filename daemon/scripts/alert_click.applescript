-- argv: <button name>. Clicks that button on iTunes' open dialog, so the user
-- can clear an alert from the remote instead of screen sharing. Only ever
-- touches a window whose subrole is AXDialog, and only a button that exists.
on run argv
    set target to (item 1 of argv) as text
    tell application "System Events"
        tell process "iTunes"
            repeat with w in windows
                try
                    if subrole of w is "AXDialog" then
                        repeat with b in buttons of w
                            if (name of b) as text is target then
                                click b
                                return "clicked"
                            end if
                        end repeat
                        error "no button named " & target & " on the dialog"
                    end if
                end try
            end repeat
        end tell
    end tell
    error "iTunes is not showing a dialog"
end run
