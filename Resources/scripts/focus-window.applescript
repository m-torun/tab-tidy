-- Argument: window id. Brings that window to the front.
on run argv
	tell application "Google Chrome"
		set index of window id (item 1 of argv) to 1
		activate
	end tell
end run
