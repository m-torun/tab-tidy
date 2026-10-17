-- Arguments: window id, tab id, window id, tab id, ...
-- Closes each tab that still exists and prints how many were closed.
on run argv
	set closed to 0
	tell application "Google Chrome"
		repeat with i from 1 to (count of argv) by 2
			set windowID to (item i of argv)
			set tabID to (item (i + 1) of argv)
			try
				close (tab id tabID of window id windowID)
				set closed to closed + 1
			end try
		end repeat
	end tell
	return closed
end run
