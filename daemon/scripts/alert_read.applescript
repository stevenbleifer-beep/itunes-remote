-- Reads any modal dialog iTunes is showing. Read-only: it never clicks.
-- Output: <joined text> US <button1> US <button2> ... , or empty when none.
-- Needs Accessibility permission for whatever runs it; returns empty without.
--
-- iTunes raises two kinds. A few are separate windows with subrole AXDialog,
-- but most — sync warnings, "some items could not be copied", store errors —
-- are sheets attached to the main window. Looking only at AXDialog windows
-- missed all of those, which is why a real iTunes error never reached the app.
--
-- A window only counts when it has at least one *named* button. Music.app's
-- main window carries subrole AXDialog, and its three buttons are the
-- unnamed close/minimise/zoom, so without that rule the app showed a sheet
-- reading "a dialog with no text" with three "missing value" buttons.
on run argv
    set US to character id 31
    try
        tell application "System Events"
            if not (exists process "iTunes") then return ""
            tell process "iTunes"
                repeat with w in windows
                    -- Sheets first: they are the modal thing in front.
                    try
                        repeat with sh in sheets of w
                            set d to my describe(sh, US)
                            if d is not "" then return d
                        end repeat
                    end try
                    try
                        if subrole of w is "AXDialog" then
                            set d to my describe(w, US)
                            if d is not "" then return d
                        end if
                    end try
                end repeat
            end tell
        end tell
    on error
        return ""
    end try
    return ""
end run

-- One dialog as text: every static line it shows, then its buttons.
on describe(w, US)
    tell application "System Events"
        set parts to {}
        try
            repeat with s in static texts of w
                try
                    set v to (value of s) as text
                    if v is not "" then set end of parts to v
                end try
            end repeat
        end try
        set msg to ""
        repeat with p in parts
            if msg is not "" then set msg to msg & "  "
            set msg to msg & p
        end repeat
        set out to msg
        set namedCount to 0
        try
            repeat with b in buttons of w
                try
                    set bn to (name of b) as text
                    if bn is not "" and bn is not "missing value" then
                        set out to out & US & bn
                        set namedCount to namedCount + 1
                    end if
                end try
            end repeat
        end try
        if namedCount is 0 then return ""
        return out
    end tell
end describe
