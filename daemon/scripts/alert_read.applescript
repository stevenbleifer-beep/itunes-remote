-- Reads any modal dialog iTunes is showing. Read-only: it never clicks.
-- Output: <joined text> US <button1> US <button2> ... , or empty when none.
-- Needs Accessibility permission for whatever runs it; returns empty without.
on run argv
    set US to character id 31
    try
        tell application "System Events"
            if not (exists process "iTunes") then return ""
            tell process "iTunes"
                repeat with w in windows
                    try
                        if subrole of w is "AXDialog" then
                            set parts to {}
                            repeat with s in static texts of w
                                try
                                    set v to (value of s) as text
                                    if v is not "" then set end of parts to v
                                end try
                            end repeat
                            set msg to ""
                            repeat with p in parts
                                if msg is not "" then set msg to msg & "  "
                                set msg to msg & p
                            end repeat
                            set out to msg
                            repeat with b in buttons of w
                                try
                                    set out to out & US & ((name of b) as text)
                                end try
                            end repeat
                            return out
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
